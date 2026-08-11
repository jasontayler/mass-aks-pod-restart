#Requires -Version 5.1
# Worker-RestartSingleCluster.ps1
# PURPOSE : Restart a named workload on a single AKS Arc cluster.
#           Fetches SA token + API server from Key Vault via himds.
#           Uses pure .NET REST -- no kubectl, no Az modules, no binary deps.
# RUNS ON : Azure Automation Hybrid Runbook Worker (on-prem, same LAN as clusters)
# CALLED BY: Shard-RestartPods.ps1 (parallel inner loop)
#
# AUTOMATION VARIABLES REQUIRED (set in Automation Account):
#   AA-KeyVaultName       : Key Vault name  e.g. "kv-aksarc-automation"
#   AA-WorkspaceId        : Log Analytics workspace ID
#   AA-WorkspaceKey       : Log Analytics workspace primary key
#   AA-SaTokenPrefix      : Secret name prefix  e.g. "satoken"     (default)
#   AA-ApiServerPrefix    : Secret name prefix  e.g. "apiserver"   (default)

param(
    [Parameter(Mandatory)][string]$ClusterName,
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$WorkloadType,   # deployment | statefulset | daemonset | pod
    [Parameter(Mandatory)][string]$WorkloadName,
    [string]$SubscriptionId  = "",                  # for audit log only
    [string]$ResourceGroup   = "",                  # for audit log only
    [string]$JobId           = "",                  # parent shard job ID
    [string]$InitiatedBy     = "AutomationRunbook",
    # Passed from Shard (which reads AA variables -- Worker runs as plain script, not AA runbook)
    [string]$KvName          = "",
    [string]$WsId            = "",
    [string]$WsKey           = "",
    [string]$SaTokenPrefix   = "satoken",
    [string]$ApiServerPrefix = "apiserver",
    # Pod-delete options (only used when WorkloadType = 'pod')
    [string]$PodDeleteMode     = "Sequential",   # Sequential | Parallel
    [int]   $PodDeleteDelayMs  = 2000            # ms between deletions in Sequential mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Resolve Shared-Functions -- works both locally (C:\Scripts\) and in Automation temp dir
$_sf = Join-Path $PSScriptRoot "Shared-Functions.ps1"
if (-not (Test-Path $_sf)) { $_sf = "C:\Scripts\Shared-Functions.ps1" }
. $_sf

# Variables passed directly from Shard (which read them from AA context)
$kvName       = $KvName
$wsId         = $WsId
$wsKey        = $WsKey
$saPrefix     = $SaTokenPrefix
$apiPrefix    = $ApiServerPrefix

if (-not $kvName) { throw "AA-KeyVaultName automation variable not set" }

$startTime    = Get-Date
$safeCluster  = $ClusterName -replace '[^a-zA-Z0-9-]','-'
$saSecretName = "$saPrefix-$safeCluster"
$apSecretName = "$apiPrefix-$safeCluster"

$auditRecord  = [ordered]@{
    TimeGenerated  = $startTime.ToString("o")
    ClusterName    = $ClusterName
    SubscriptionId = $SubscriptionId
    ResourceGroup  = $ResourceGroup
    Namespace      = $Namespace
    WorkloadType   = $WorkloadType
    WorkloadName   = $WorkloadName
    Status         = "Started"
    HttpStatus     = 0
    DurationMs     = 0
    InitiatedBy    = $InitiatedBy
    JobId          = $JobId
    ShardId        = $env:COMPUTERNAME
    ErrorDetail    = ""
    # Pod-delete fields (populated only when WorkloadType = 'pod'; 0 otherwise)
    PodsFound      = 0
    PodsDeleted    = 0
    PodsSkipped    = 0
}

function Finish {
    param([string]$Status, [int]$Http = 0, [string]$Err = "")
    $auditRecord.Status    = $Status
    $auditRecord.HttpStatus= $Http
    $auditRecord.DurationMs= [Math]::Round((New-TimeSpan $startTime (Get-Date)).TotalMilliseconds)
    $auditRecord.ErrorDetail = $Err
    if ($wsId -and $wsKey) { Write-AuditLog -WorkspaceId $wsId -WorkspaceKey $wsKey -Record $auditRecord }
    $col = if ($Status -eq "Success") {'Green'} elseif ($Status -eq "Skipped") {'Yellow'} else {'Red'}
    Write-Host "[$ClusterName] $Status  ${WorkloadType}/$WorkloadName  $($auditRecord.DurationMs)ms" -ForegroundColor $col
}

try {
    # 1. Tokens
    Write-Verbose "Getting tokens..."
    $kvToken  = Get-HimdsToken -Resource "https://vault.azure.net"

    # 2. SA token from Key Vault
    Write-Verbose "Fetching SA token from KV: $saSecretName"
    $saToken = Get-KvSecret -VaultName $kvName -SecretName $saSecretName -KvToken $kvToken

    # 3. API server address from Key Vault
    Write-Verbose "Fetching API server from KV: $apSecretName"
    $apiServer = Get-KvSecret -VaultName $kvName -SecretName $apSecretName -KvToken $kvToken

    $apiHost = $apiServer -replace ':.*',''
    $apiPort = if ($apiServer -match ':(\d+)$') { [int]$Matches[1] } else { 6443 }

    # 4. TCP connectivity check (fast fail)
    if (-not (Test-TcpPort -Hostname $apiHost -Port $apiPort -TimeoutMs 3000)) {
        Finish -Status "NetworkError" -Err "TCP timeout to $apiServer"
        return
    }

    # 5a. Pod-delete path (WorkloadType = 'pod').
    #     WorkloadName is treated as a Kubernetes label selector string,
    #     e.g. "app.kubernetes.io/name=aksarc-telemetry" or "app=myapp,tier=backend".
    #
    # IMPORTANT LIMITATIONS (documented by design):
    #   - Direct DELETE bypasses PodDisruptionBudgets -- the Kubernetes API server does not
    #     enforce PDB on DELETE requests. The PDB check below is advisory (warn-only).
    #   - No rolling strategy: Sequential mode adds a configurable delay between deletions
    #     but does not coordinate with the controller's maxUnavailable / maxSurge.
    #   - StatefulSet pods with quorum requirements (e.g. etcd, Kafka) should be targeted
    #     one pod at a time via separate job runs.
    if ($WorkloadType.ToLower() -in @('pod','pods')) {

        # 5a-i. List pods matching the label selector
        $labelSelector = [uri]::EscapeDataString($WorkloadName)
        Write-Verbose "Listing pods with labelSelector: $WorkloadName"
        $listResp = Invoke-K8sRest -ApiServer $apiServer `
            -Path "/api/v1/namespaces/$Namespace/pods?labelSelector=$labelSelector" `
            -Token $saToken
        if (-not $listResp.Ok) {
            throw "LIST pods returned HTTP $($listResp.StatusCode): $($listResp.Body.Substring(0,[Math]::Min(200,$listResp.Body.Length)))"
        }
        $podList = ($listResp.Body | ConvertFrom-Json).items
        if (-not $podList) { $podList = @() }
        $auditRecord.PodsFound = $podList.Count
        Write-Host "[$ClusterName] Found $($podList.Count) pod(s) matching '$WorkloadName'" -ForegroundColor DarkGray

        if ($podList.Count -eq 0) {
            Finish -Status "Skipped" -Http 200 -Err "No pods matched label selector '$WorkloadName' in $Namespace"
            return
        }

        # 5a-ii. Fetch PodDisruptionBudgets for advisory PDB check (warn-only; never blocks).
        #        Note: K8s API does NOT enforce PDB on direct DELETE -- this check is informational.
        $pdbMap = @{}   # key = pod name, value = PDB name that covers it
        $pdbResp = Invoke-K8sRest -ApiServer $apiServer `
            -Path "/apis/policy/v1/namespaces/$Namespace/poddisruptionbudgets" `
            -Token $saToken
        if ($pdbResp.Ok) {
            $pdbList = ($pdbResp.Body | ConvertFrom-Json).items
            if (-not $pdbList) { $pdbList = @() }
            foreach ($pdb in $pdbList) {
                $pdbLabels = $pdb.spec.selector.matchLabels
                if (-not $pdbLabels) { continue }
                $disruptionsAllowed = [int]$pdb.status.disruptionsAllowed
                foreach ($pod in $podList) {
                    $podLabels = $pod.metadata.labels
                    if (-not $podLabels) { continue }
                    # Check if all PDB selector labels are present in pod labels
                    $covered = $true
                    foreach ($k in $pdbLabels.PSObject.Properties.Name) {
                        if ($podLabels.$k -ne $pdbLabels.$k) { $covered = $false; break }
                    }
                    if ($covered -and $disruptionsAllowed -eq 0) {
                        $pdbMap[$pod.metadata.name] = $pdb.metadata.name
                        Write-Warning "[$ClusterName] Pod '$($pod.metadata.name)' is covered by PDB '$($pdb.metadata.name)' with disruptionsAllowed=0. Proceeding anyway -- direct DELETE bypasses PDB enforcement."
                    }
                }
            }
        } else {
            Write-Host "[$ClusterName] Could not fetch PDBs (HTTP $($pdbResp.StatusCode)) -- skipping PDB check" -ForegroundColor DarkGray
        }

        # 5a-iii. Filter pods: skip already-Terminating, skip unmanaged (no ownerReferences)
        $toDelete = [System.Collections.Generic.List[string]]::new()
        foreach ($pod in $podList) {
            $podName = $pod.metadata.name
            if ($pod.metadata.deletionTimestamp) {
                Write-Host "[$ClusterName]   Skipping '$podName' (already Terminating)" -ForegroundColor DarkGray
                $auditRecord.PodsSkipped++
                continue
            }
            $owners = $pod.metadata.ownerReferences
            if (-not $owners -or @($owners).Count -eq 0) {
                Write-Warning "[$ClusterName] Skipping '$podName' -- pod has no ownerReference (not managed by any controller; deletion is permanent)"
                $auditRecord.PodsSkipped++
                continue
            }
            $toDelete.Add($podName)
        }

        if ($toDelete.Count -eq 0) {
            Finish -Status "Skipped" -Http 200 -Err "All $($podList.Count) matched pod(s) were skipped (Terminating or unmanaged)"
            return
        }

        Write-Host "[$ClusterName] Deleting $($toDelete.Count) pod(s) [mode: $PodDeleteMode]" -ForegroundColor Yellow

        # 5a-iv. Delete pods
        $deleteErrors = [System.Collections.Generic.List[string]]::new()
        if ($PodDeleteMode.ToLower() -eq 'parallel') {
            foreach ($podName in $toDelete) {
                $delResp = Invoke-K8sRest -ApiServer $apiServer `
                    -Path "/api/v1/namespaces/$Namespace/pods/$podName" `
                    -Token $saToken -Method "DELETE"
                if ($delResp.Ok -or $delResp.StatusCode -eq 404) {
                    Write-Host "[$ClusterName]   Deleted '$podName' (HTTP $($delResp.StatusCode))" -ForegroundColor DarkGray
                    $auditRecord.PodsDeleted++
                } else {
                    $errSnip = $delResp.Body.Substring(0,[Math]::Min(200,$delResp.Body.Length))
                    Write-Warning "[$ClusterName]   DELETE '$podName' failed HTTP $($delResp.StatusCode): $errSnip"
                    $deleteErrors.Add("$podName HTTP$($delResp.StatusCode)")
                    $auditRecord.PodsSkipped++
                }
            }
        } else {
            # Sequential (default): pause between deletions to reduce outage risk
            for ($pi = 0; $pi -lt $toDelete.Count; $pi++) {
                $podName = $toDelete[$pi]
                $delResp = Invoke-K8sRest -ApiServer $apiServer `
                    -Path "/api/v1/namespaces/$Namespace/pods/$podName" `
                    -Token $saToken -Method "DELETE"
                if ($delResp.Ok -or $delResp.StatusCode -eq 404) {
                    Write-Host "[$ClusterName]   Deleted '$podName' (HTTP $($delResp.StatusCode))" -ForegroundColor DarkGray
                    $auditRecord.PodsDeleted++
                } else {
                    $errSnip = $delResp.Body.Substring(0,[Math]::Min(200,$delResp.Body.Length))
                    Write-Warning "[$ClusterName]   DELETE '$podName' failed HTTP $($delResp.StatusCode): $errSnip"
                    $deleteErrors.Add("$podName HTTP$($delResp.StatusCode)")
                    $auditRecord.PodsSkipped++
                }
                # Delay between deletions (skip after the last pod)
                if ($pi -lt ($toDelete.Count - 1)) {
                    Start-Sleep -Milliseconds $PodDeleteDelayMs
                }
            }
        }

        if ($deleteErrors.Count -eq 0) {
            Finish -Status "Success" -Http 200
        } else {
            $errDetail = "Delete failures: $($deleteErrors -join ', ')"
            Finish -Status "Failed" -Err $errDetail
            throw $errDetail
        }
        return
    }

    # 5b. Normalise workload type to API group path (deployment / statefulset / daemonset)
    $typeMap = @{
        "deployment"  = "deployments"
        "deployments" = "deployments"
        "statefulset" = "statefulsets"
        "statefulsets"= "statefulsets"
        "daemonset"   = "daemonsets"
        "daemonsets"  = "daemonsets"
    }
    $apiType = $typeMap[$WorkloadType.ToLower()]
    if (-not $apiType) { throw "Unknown workload type '$WorkloadType'. Use: deployment, statefulset, daemonset, pod" }

    # 6. Verify workload exists
    Write-Verbose "Checking workload exists..."
    $getResp = Invoke-K8sRest -ApiServer $apiServer `
        -Path "/apis/apps/v1/namespaces/$Namespace/$apiType/$WorkloadName" `
        -Token $saToken
    if ($getResp.StatusCode -eq 404) {
        Finish -Status "Skipped" -Http 404 -Err "Workload $apiType/$WorkloadName not found in $Namespace"
        return
    }
    if (-not $getResp.Ok) {
        throw "GET $apiType/$WorkloadName returned HTTP $($getResp.StatusCode): $($getResp.Body.Substring(0,[Math]::Min(200,$getResp.Body.Length)))"
    }

    # 7. PATCH restart annotation
    $ts    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $patch = "{`"spec`":{`"template`":{`"metadata`":{`"annotations`":{`"kubectl.kubernetes.io/restartedAt`":`"$ts`"}}}}}"

    Write-Verbose "PATCHing $apiType/$WorkloadName..."
    $patchResp = Invoke-K8sRest -ApiServer $apiServer `
        -Path "/apis/apps/v1/namespaces/$Namespace/$apiType/$WorkloadName" `
        -Token $saToken `
        -Method "PATCH" `
        -Body $patch

    if ($patchResp.Ok) {
        Finish -Status "Success" -Http $patchResp.StatusCode
    } else {
        $errSnip = $patchResp.Body.Substring(0,[Math]::Min(300,$patchResp.Body.Length))
        Finish -Status "Failed" -Http $patchResp.StatusCode -Err $errSnip
        throw "PATCH failed HTTP $($patchResp.StatusCode): $errSnip"
    }

} catch {
    Finish -Status "Failed" -Err $_.Exception.Message
    throw
}
