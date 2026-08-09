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
    [Parameter(Mandatory)][string]$WorkloadType,   # deployment | statefulset | daemonset
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
    [string]$ApiServerPrefix = "apiserver"
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

    # 5. Normalise workload type to API group path
    $typeMap = @{
        "deployment"  = "deployments"
        "deployments" = "deployments"
        "statefulset" = "statefulsets"
        "statefulsets"= "statefulsets"
        "daemonset"   = "daemonsets"
        "daemonsets"  = "daemonsets"
    }
    $apiType = $typeMap[$WorkloadType.ToLower()]
    if (-not $apiType) { throw "Unknown workload type '$WorkloadType'. Use: deployment, statefulset, daemonset" }

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
