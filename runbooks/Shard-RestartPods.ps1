#Requires -Version 5.1
# Shard-RestartPods.ps1
# PURPOSE : Inner parallel loop. Receives a chunk of clusters and calls
#           Worker-RestartSingleCluster for each in parallel.
# RUNS ON : Azure Automation Hybrid Runbook Worker (PS7.2)
# CALLED BY: Master-FleetRestart.ps1

param(
    [Parameter(Mandatory)][string]$ClustersData,    # "name|rg|subId;name|rg|subId;..." plain text
    [Parameter(Mandatory)][string]$Namespace,
    [Parameter(Mandatory)][string]$WorkloadType,
    [Parameter(Mandatory)][string]$WorkloadName,
    [string]$JobId         = "",
    [string]$InitiatedBy   = "AutomationRunbook",
    [int]   $ThrottleLimit = 50,
    # Pod-delete options -- forwarded verbatim to Worker-RestartSingleCluster.ps1
    [string]$PodDeleteMode    = "Sequential",   # Sequential | Parallel
    [int]   $PodDeleteDelayMs = 2000            # ms between deletions in Sequential mode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

# Resolve Shared-Functions
$_sf = Join-Path $PSScriptRoot "Shared-Functions.ps1"
if (-not (Test-Path $_sf)) { $_sf = "C:\Scripts\Shared-Functions.ps1" }
. $_sf

# Resolve Worker script path
$_scriptDir = if (Test-Path (Join-Path $PSScriptRoot "Worker-RestartSingleCluster.ps1")) {
    $PSScriptRoot
} else { "C:\Scripts" }

# Read AA variables HERE -- Worker runs as plain local script, cannot call Get-AutomationVariable
function Get-AaVar { param([string]$n,[string]$d="") try { Get-AutomationVariable -Name $n } catch { $d } }
$_kvName    = Get-AaVar "AA-KeyVaultName"
$_wsId      = Get-AaVar "AA-WorkspaceId"
$_wsKey     = Get-AaVar "AA-WorkspaceKey"
$_saPrefix  = Get-AaVar "AA-SaTokenPrefix"  "satoken"
$_apiPrefix = Get-AaVar "AA-ApiServerPrefix" "apiserver"

if (-not $_kvName) { throw "AA-KeyVaultName automation variable not set" }
Write-Host "KV: $_kvName  saPrefix: $_saPrefix  apiPrefix: $_apiPrefix" -ForegroundColor Cyan

# Parse plain-text cluster list: "name|rg|subId;name|rg|subId;..."
# Plain text avoids AA CliXml/JSON double-encoding issues with string parameters.
Write-Host "  ClustersData: $($ClustersData.Length) chars" -ForegroundColor DarkGray
$clusters = @($ClustersData -split ';' | Where-Object { $_.Trim() } | ForEach-Object {
    $parts = $_ -split '~'   # ~ delimiter; | was treated as a pipeline operator by the Hybrid Worker shell
    [PSCustomObject]@{ name=$parts[0]; resourceGroup=$parts[1]; subscriptionId=$parts[2] }
})
Write-Host "Shard starting: $($clusters.Count) clusters, workload=$WorkloadType/$WorkloadName, ns=$Namespace" -ForegroundColor Cyan

$results    = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()
$shardStart = Get-Date

$clusters | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
    $cl        = $_
    $ns        = $using:Namespace
    $wtype     = $using:WorkloadType
    $wname     = $using:WorkloadName
    $jid       = $using:JobId
    $initBy    = $using:InitiatedBy
    $bag       = $using:results
    $scriptDir = $using:_scriptDir
    $kvName    = $using:_kvName
    $wsId      = $using:_wsId
    $wsKey     = $using:_wsKey
    $saPrefix  = $using:_saPrefix
    $apiPrefix = $using:_apiPrefix
    $podMode   = $using:PodDeleteMode
    $podDelay  = $using:PodDeleteDelayMs

    $r = [PSCustomObject]@{ Cluster=$cl.name; Status="Unknown"; DurationMs=0; Error="" }
    $t0 = Get-Date
    try {
        $workerScript = Join-Path $scriptDir "Worker-RestartSingleCluster.ps1"
        & $workerScript `
            -ClusterName     $cl.name `
            -Namespace       $ns `
            -WorkloadType    $wtype `
            -WorkloadName    $wname `
            -SubscriptionId  $cl.subscriptionId `
            -ResourceGroup   $cl.resourceGroup `
            -JobId           $jid `
            -InitiatedBy     $initBy `
            -KvName          $kvName `
            -WsId            $wsId `
            -WsKey           $wsKey `
            -SaTokenPrefix   $saPrefix `
            -ApiServerPrefix $apiPrefix `
            -PodDeleteMode   $podMode `
            -PodDeleteDelayMs $podDelay `
            -ErrorAction Stop
        $r.Status = "Success"
    } catch {
        $r.Status = "Failed"
        $r.Error  = $_.Exception.Message
    }
    $r.DurationMs = [Math]::Round((New-TimeSpan $t0 (Get-Date)).TotalMilliseconds)
    $bag.Add($r)
}

$elapsed = [Math]::Round((New-TimeSpan $shardStart (Get-Date)).TotalMilliseconds)
$ok      = @($results | Where-Object Status -eq "Success").Count
$fail    = @($results | Where-Object Status -ne "Success").Count

Write-Host "Shard complete: $ok success, $fail failed, ${elapsed}ms total" -ForegroundColor $(if ($fail -eq 0){'Green'} else {'Yellow'})
$results | ForEach-Object {
    $col = if ($_.Status -eq "Success"){'Green'} elseif ($_.Status -eq "Skipped"){'Yellow'} else {'Red'}
    Write-Host "  $($_.Cluster): $($_.Status) ($($_.DurationMs)ms) $($_.Error)" -ForegroundColor $col
}

$summary = [PSCustomObject]@{
    ShardId   = $env:COMPUTERNAME
    Total     = $results.Count
    Success   = $ok
    Failed    = $fail
    ElapsedMs = $elapsed
    Failures  = @($results | Where-Object Status -ne "Success" | Select-Object Cluster, Status, Error)
}
return ($summary | ConvertTo-Json -Compress)
