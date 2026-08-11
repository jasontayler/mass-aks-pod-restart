#Requires -Version 5.1
# Master-FleetRestart.ps1
# PURPOSE : Orchestrates pod/deployment/statefulset restarts across all clusters
#           in one or more subscriptions. Discovers clusters via Azure Resource
#           Graph, shards them across Hybrid Workers, collects results.
# RUNS ON : Azure Automation cloud sandbox OR Hybrid Runbook Worker.
#           Child jobs are submitted via ARM REST (management.azure.com) rather
#           than Start-AutomationRunbook so that the JRDS internal channel is
#           not required -- works through corporate proxy and from Hybrid Workers.
#
# AUTOMATION VARIABLES REQUIRED:
#   AA-SubscriptionIds   : Comma-separated subscription IDs to scan
#   AA-HybridWorkerGroup : Automation Hybrid Worker Group name
#   AA-AccountName       : Automation Account name (used for ARM job submission + polling)
#   AA-ResourceGroup     : Resource group of the Automation Account
#   AA-KeyVaultName      : Key Vault name
#   AA-WorkspaceId       : Log Analytics workspace ID
#   AA-WorkspaceKey      : Log Analytics workspace key
#
# PARAMETERS (passed at job start or via Azure Portal / Logic App):
#   -Namespace    : K8s namespace to restart in
#   -WorkloadType : deployment | statefulset | daemonset
#   -WorkloadName : exact name of the workload
#   -ClusterFilter: optional Resource Graph where clause to narrow clusters

param(
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$WorkloadType,
    [Parameter(Mandatory)][string]$WorkloadName,
    [string]$ClusterFilter  = "",      # e.g. "| where tags.environment == 'prod'"
    [int]   $ShardSize      = 50,      # clusters per shard/child job
    [int]   $JobTimeoutSec  = 600,     # max wait per shard
    [string]$InitiatedBy    = ""          # blank = auto-detect from job metadata; Logic App passes explicitly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Get Automation variables ─────────────────────────────────────────────────
function Get-AaVar { param([string]$n,[string]$d="") try { Get-AutomationVariable -Name $n } catch { $d } }

$subscriptionIds  = (Get-AaVar "AA-SubscriptionIds") -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$hybridGroup      = Get-AaVar "AA-HybridWorkerGroup"
$wsId             = Get-AaVar "AA-WorkspaceId"
$wsKey            = Get-AaVar "AA-WorkspaceKey"
$aaAcctName       = Get-AutomationVariable -Name "AA-AccountName"
$aaRgName         = Get-AutomationVariable -Name "AA-ResourceGroup"
$jobId            = if ($PSPrivateMetadata.JobId) { $PSPrivateMetadata.JobId.ToString() } else { [guid]::NewGuid().ToString() }

if (-not $subscriptionIds) { throw "AA-SubscriptionIds automation variable not set" }
if (-not $hybridGroup)     { throw "AA-HybridWorkerGroup automation variable not set" }
if (-not $aaAcctName)      { throw "AA-AccountName automation variable not set" }
if (-not $aaRgName)        { throw "AA-ResourceGroup automation variable not set" }

Write-Output "Fleet restart starting -- JobId: $jobId"
Write-Output "Workload: $WorkloadType/$WorkloadName in namespace: $Namespace"
Write-Output "Subscriptions: $($subscriptionIds -join ', ')"

$masterStart = Get-Date

# ── Get ARM token via Managed Identity ───────────────────────────────────────
# Works in both cloud sandbox (IDENTITY_ENDPOINT env var) and Hybrid Worker
# (HIMDS endpoint on localhost:40342). Falls through in order.
function Get-MsiToken {
    param([string]$Resource = "https://management.azure.com/")

    # Cloud sandbox / Extension-based Hybrid Worker (preferred)
    if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
        $url = "$($env:IDENTITY_ENDPOINT)?resource=$([uri]::EscapeDataString($Resource))&api-version=2019-08-01"
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = "GET"
        $req.Headers.Add("X-IDENTITY-HEADER", $env:IDENTITY_HEADER)
        $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()  # bypass proxy for localhost
        $resp = $req.GetResponse()
        $body = [System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd()
        $resp.Close()
        return ($body | ConvertFrom-Json).access_token
    }

    # Agent-based Hybrid Worker: HIMDS on localhost
    $himds = "http://localhost:40342/metadata/identity/oauth2/token?api-version=2019-11-01&resource=$([uri]::EscapeDataString($Resource))"
    try {
        $req = [System.Net.HttpWebRequest]::Create($himds)
        $req.Method = "GET"
        $req.Headers.Add("Metadata", "true")
        $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()  # bypass proxy for localhost
        $resp = $req.GetResponse()
        $body = [System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd()
        $resp.Close()
        return ($body | ConvertFrom-Json).access_token
    } catch { }

    throw "MSI token endpoint not available. Ensure Managed Identity is enabled on the Automation Account and the Hybrid Worker has Arc Connected Machine Agent installed."
}

# ARM GET/POST/PUT helper using HttpWebRequest
# Uses system proxy with default credentials -- works through corporate proxy.
function Invoke-ArmApi {
    param(
        [string]$Uri,
        [string]$Method  = "GET",
        [string]$Token,
        [string]$Body    = ""
    )
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = $Method
    $req.Headers.Add("Authorization", "Bearer $Token")
    $req.Accept = "application/json"
    # Use system proxy with default Windows credentials (handles corporate proxy/NTLM/Kerberos)
    $proxy = [System.Net.WebRequest]::GetSystemWebProxy()
    $proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    $req.Proxy = $proxy
    if ($Body) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentType   = "application/json"
        $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream(); $s.Write($bytes,0,$bytes.Length); $s.Close()
    } else { $req.ContentLength = 0 }
    $resp = $req.GetResponse()
    $json = [System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd()
    $resp.Close()
    if ($json) { return $json | ConvertFrom-Json }
}

$armToken = Get-MsiToken "https://management.azure.com/"
Write-Output "ARM token acquired via MSI"

# ── Build AA base URI (used for job submission AND polling) ───────────────────
$subId0    = @($subscriptionIds)[0]
$aaJobBase = "https://management.azure.com/subscriptions/$subId0/resourceGroups/$aaRgName/providers/Microsoft.Automation/automationAccounts/$aaAcctName"
Write-Output "Automation Account: $aaAcctName (RG: $aaRgName)"

# ── Resolve initiator identity ────────────────────────────────────────────────
# Logic App passes InitiatedBy explicitly. Portal/API starts: Azure scrubs the
# UPN to '{scrubbed}' when the account's own MI reads the job -- fall back to "Portal".
if (-not $InitiatedBy -and $PSPrivateMetadata.JobId) {
    try {
        $jobMeta   = Invoke-ArmApi -Uri "$aaJobBase/jobs/${jobId}?api-version=2023-11-01" -Token $armToken
        $startedBy = $jobMeta.properties.startedBy
        if ($startedBy -and $startedBy -ne '{scrubbed}') { $InitiatedBy = $startedBy }
    } catch {
        Write-Output "  (Could not resolve initiator from job metadata: $($_.Exception.Message))"
    }
}
if (-not $InitiatedBy) { $InitiatedBy = "Portal" }
Write-Output "Initiated by: $InitiatedBy"

# ── Discover clusters via Resource Graph ─────────────────────────────────────
Write-Output "Discovering connected clusters via Resource Graph..."

$allClusters = [System.Collections.Generic.List[PSCustomObject]]::new()

$graphUri   = "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01"
$graphQuery = @"
Resources
| where type =~ 'microsoft.kubernetes/connectedclusters'
| where properties.connectivityStatus =~ 'Connected'
$ClusterFilter
| project name, resourceGroup, subscriptionId
"@

$resp = Invoke-ArmApi -Uri $graphUri -Method POST -Token $armToken `
    -Body (@{ query=$graphQuery; subscriptions=@($subscriptionIds) } | ConvertTo-Json -Depth 5)

# PS5.1 ConvertFrom-Json returns a single object (not array) when there's 1 result -- force array
$respData = @($resp.data)

foreach ($row in $respData) {
    $allClusters.Add([PSCustomObject]@{
        name           = $row.name
        resourceGroup  = $row.resourceGroup
        subscriptionId = $row.subscriptionId
    })
}
Write-Output "  Resource Graph returned $($respData.Count) clusters across $(@($subscriptionIds).Count) subscription(s)"

$total = $allClusters.Count
Write-Output "Total clusters discovered: $total"

if ($total -eq 0) {
    Write-Output "No clusters found. Check connectivity status and ClusterFilter."
    exit 0
}

# ── Shard clusters ────────────────────────────────────────────────────────────
$shards = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $total; $i += $ShardSize) {
    $chunk = $allClusters | Select-Object -Skip $i -First $ShardSize
    $shards.Add(@($chunk))
}
Write-Output "Sharding into $($shards.Count) child jobs (max $ShardSize clusters each)..."

# ── Launch child runbooks via ARM REST (no Start-AutomationRunbook / JRDS needed) ──
# PUT /automationAccounts/{aa}/jobs/{guid} submits a job directly via management.azure.com.
# This works from Hybrid Workers through corporate proxy -- avoids the JRDS internal
# channel that Start-AutomationRunbook relies on.
$jobs = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($shard in $shards) {
    $clusterData = (@($shard) | ForEach-Object { "$($_.name)~$($_.resourceGroup)~$($_.subscriptionId)" }) -join ";"  # ~ is safe; | is a pipeline operator on the HW command line
    $shardJobId  = [guid]::NewGuid().ToString()

    $jobBody = @{
        properties = @{
            runbook    = @{ name = "Shard-RestartPods" }
            runOn      = $hybridGroup
            parameters = @{
                ClustersData = $clusterData
                Namespace    = $Namespace
                WorkloadType = $WorkloadType
                WorkloadName = $WorkloadName
                JobId        = $jobId
                InitiatedBy  = $InitiatedBy
            }
        }
    } | ConvertTo-Json -Depth 10

    Invoke-ArmApi -Uri "$aaJobBase/jobs/${shardJobId}?api-version=2023-11-01" `
                  -Method PUT -Token $armToken -Body $jobBody | Out-Null

    $jobs.Add([PSCustomObject]@{ JobId=$shardJobId; ShardSize=@($shard).Count })
    Write-Output "  Started shard job $shardJobId ($(@($shard).Count) clusters)"
}

# ── Wait for all shards via ARM REST ─────────────────────────────────────────
Write-Output "Waiting for $($jobs.Count) shard jobs..."
$totalSuccess = 0; $totalFailed = 0; $allFailures = @()

foreach ($j in $jobs) {
    $deadline = (Get-Date).AddSeconds($JobTimeoutSec)
    $state    = "Running"
    $jobUri   = "$aaJobBase/jobs/$($j.JobId)?api-version=2023-11-01"

    Write-Output "  Polling shard $($j.JobId)..."
    do {
        Start-Sleep -Seconds 10
        try {
            $jobStatus = Invoke-ArmApi -Uri $jobUri -Token $armToken
            $state = $jobStatus.properties.status
            Write-Output "    status: $state"
        } catch { $state = "Unknown" }
    } while ($state -notin @('Completed','Failed','Stopped','Suspended') -and (Get-Date) -lt $deadline)

    Write-Output "  Shard $($j.JobId) final state: $state"
    if ($state -eq 'Completed') {
        $totalSuccess += $j.ShardSize
    } else {
        Write-Warning "Shard job $($j.JobId) ended with state: $state"
        $totalFailed += $j.ShardSize
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
$elapsed = [Math]::Round((New-TimeSpan $masterStart (Get-Date)).TotalSeconds, 1)

Write-Output ""
Write-Output "================================================================"
Write-Output "  FLEET RESTART COMPLETE"
Write-Output "  Workload  : $WorkloadType/$WorkloadName"
Write-Output "  Namespace : $Namespace"
Write-Output "  Total     : $total  Success: $totalSuccess  Failed: $totalFailed"
Write-Output "  Duration  : ${elapsed}s"
Write-Output "  JobId     : $jobId"
Write-Output "  InitiatedBy: $InitiatedBy"
Write-Output "================================================================"

if ($allFailures.Count -gt 0) {
    Write-Output "Failed clusters:"
    $allFailures | ForEach-Object { Write-Output "  $($_.Cluster): $($_.Error)" }
}

# Write master audit record
if ($wsId -and $wsKey) {
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes((@{
        TimeGenerated = (Get-Date).ToString("o")
        EventType     = "FleetRestartComplete"
        WorkloadType  = $WorkloadType
        WorkloadName  = $WorkloadName
        Namespace     = $Namespace
        TotalClusters = $total
        Success       = $totalSuccess
        Failed        = $totalFailed
        DurationSec   = $elapsed
        JobId         = $jobId
        InitiatedBy   = $InitiatedBy
    } | ConvertTo-Json -Compress))
    $dateStr   = [DateTime]::UtcNow.ToString("R")
    $strToSign = "POST`n$($bodyBytes.Length)`napplication/json`nx-ms-date:$dateStr`n/api/logs"
    $hmac      = [System.Security.Cryptography.HMACSHA256]::new([Convert]::FromBase64String($wsKey))
    $sig       = [Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($strToSign)))
    try {
        $lawReq = [System.Net.HttpWebRequest]::Create("https://$wsId.ods.opinsights.azure.com/api/logs?api-version=2016-04-01")
        $lawReq.Method = "POST"
        $lawProxy = [System.Net.WebRequest]::GetSystemWebProxy()
        $lawProxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
        $lawReq.Proxy = $lawProxy
        $lawReq.ContentType = "application/json"
        $lawReq.Headers.Add("Log-Type", "AKSArcRestart")
        $lawReq.Headers.Add("x-ms-date", $dateStr)
        $lawReq.Headers.Add("Authorization", "SharedKey ${wsId}:${sig}")
        $lawReq.ContentLength = $bodyBytes.Length
        $ls = $lawReq.GetRequestStream(); $ls.Write($bodyBytes,0,$bodyBytes.Length); $ls.Close()
        $lawReq.GetResponse().Close()
    } catch { Write-Output "  (Audit log write failed: $($_.Exception.Message))" }
}

if ($totalFailed -gt 0) { exit 1 }