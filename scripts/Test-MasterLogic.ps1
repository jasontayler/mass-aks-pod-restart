#Requires -Version 5.1
# Test-MasterLogic.ps1
# PURPOSE : Validates the Master runbook's ARM token + Resource Graph logic
#           directly on the Hybrid Worker -- much faster than AA trial/error.
# RUN ON  : Hybrid Worker (GITHUBRUN) as Administrator
# USAGE   : .\Test-MasterLogic.ps1 -SubscriptionId 'e858a6b1-...'

param(
    [Parameter(Mandatory)][string]$SubscriptionId
)

# Use the proven Shared-Functions (already validated end-to-end)
$sf = "C:\Scripts\Shared-Functions.ps1"
if (-not (Test-Path $sf)) { $sf = Join-Path $PSScriptRoot "..\runbooks\Shared-Functions.ps1" }
if (-not (Test-Path $sf)) { throw "Cannot find Shared-Functions.ps1 -- copy it to C:\Scripts\ first" }
. $sf

function Write-Step { param([int]$n,[string]$msg) Write-Host "`n[$n] $msg..." -ForegroundColor Cyan }
function Write-OK   { param([string]$msg) Write-Host "  OK -- $msg" -ForegroundColor Green }
function Write-Fail { param([string]$msg) Write-Host "  FAIL -- $msg" -ForegroundColor Red; exit 1 }

# ARM POST/GET helper (same as Master runbook uses)
function Invoke-ArmApi {
    param([string]$Uri,[string]$Method="GET",[string]$Token,[string]$Body="")
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method = $Method
    $req.Headers.Add("Authorization", "Bearer $Token")
    $req.Accept = "application/json"
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

# ── [1] Get ARM token via himds (proven Get-HimdsToken from Shared-Functions) ─
Write-Step 1 "Getting ARM token via himds"
try {
    $armToken = Get-HimdsToken "https://management.azure.com/"
    Write-OK "$($armToken.Length) char token"
} catch {
    Write-Fail "himds ARM token: $($_.Exception.Message)"
}

# ── [2a] Broad query -- check if this identity can see ANY resources ───────────
Write-Step 2 "Resource Graph -- broad check (any resources visible to this identity)"
try {
    $graphUri  = "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01"
    $broadResp = Invoke-ArmApi -Uri $graphUri -Method POST -Token $armToken `
        -Body (@{ query="Resources | summarize count() by type | order by count_ desc | take 10"; subscriptions=@($SubscriptionId) } | ConvertTo-Json)
    if ($broadResp.data.Count -eq 0) {
        Write-Host "  WARN -- 0 resources visible. This identity has no Reader RBAC on sub $SubscriptionId." -ForegroundColor Yellow
        Write-Host "         The actual Master runbook uses the AA MSI which likely DOES have access." -ForegroundColor Yellow
        Write-Host "         This test identity (Arc machine GITHUBRUN) needs 'Reader' on the sub to validate here." -ForegroundColor Yellow
    } else {
        Write-OK "$($broadResp.data.Count) resource types visible"
        $broadResp.data | ForEach-Object { Write-Host "    $($_.type): $($_.'count_')" }
    }
} catch {
    Write-Host "  WARN -- broad query failed: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ── [2b] Connected clusters query (with status dump) ─────────────────────────
Write-Step 3 "Resource Graph -- all connectedclusters (no status filter)"
try {
    $allClustersResp = Invoke-ArmApi -Uri $graphUri -Method POST -Token $armToken `
        -Body (@{ query="Resources | where type =~ 'microsoft.kubernetes/connectedclusters' | project name, resourceGroup, subscriptionId, connectivityStatus=tostring(properties.connectivityStatus)"; subscriptions=@($SubscriptionId) } | ConvertTo-Json)
    if ($allClustersResp.data.Count -eq 0) {
        Write-Host "  WARN -- 0 connectedclusters visible (RBAC gap on this identity -- OK for test, not for runbook)" -ForegroundColor Yellow
    } else {
        Write-OK "$($allClustersResp.data.Count) total clusters (all statuses)"
        $allClustersResp.data | ForEach-Object {
            Write-Host "    - $($_.name)  status=$($_.connectivityStatus)" -ForegroundColor $(if ($_.connectivityStatus -eq 'Connected'){'Green'} else {'Yellow'})
        }
    }
    $clusters = @($allClustersResp.data | Where-Object { $_.connectivityStatus -eq 'Connected' })
} catch {
    Write-Fail "Resource Graph: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "  NOTE: If 0 results above, grant 'Reader' to the Arc machine identity of GITHUBRUN" -ForegroundColor Cyan
Write-Host "        OR just re-import and run Master runbook -- it uses the AA MSI (different identity)" -ForegroundColor Cyan

# ── [4] KV token (proves MI has KV access) ────────────────────────────────────
Write-Step 4 "Getting KV token via himds"
try {
    $kvToken = Get-HimdsToken "https://vault.azure.net/"
    Write-OK "$($kvToken.Length) char KV token"
} catch {
    Write-Fail "himds KV token: $($_.Exception.Message)"
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  ARM token: OK  |  KV token: OK" -ForegroundColor Green
Write-Host "  Resource Graph: $($clusters.Count) Connected clusters visible to this identity" -ForegroundColor $(if($clusters.Count -gt 0){'Green'} else {'Yellow'})
Write-Host "  If 0 clusters: AA MSI needs 'Reader' on sub, OR check AA Identity is enabled." -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Green
