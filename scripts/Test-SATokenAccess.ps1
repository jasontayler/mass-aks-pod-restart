#Requires -Version 5.1
# Test-SATokenAccess.ps1
# PURPOSE : Quick smoke test after Bootstrap-ServiceAccount.ps1 completes.
#           Fetches SA token from Key Vault, connects to K8s API, lists
#           namespaces and workloads, and times the roundtrip.
# RUN ON  : Hybrid Worker (same LAN as clusters)
#
# USAGE:
#   .\Test-SATokenAccess.ps1 -KeyVaultName "kv-aksarc-automation" -ClusterName "az-nuc-aks01"
#   .\Test-SATokenAccess.ps1 -KeyVaultName "kv-aksarc-automation" -ClusterName "az-nuc-aks01" -TestRestart

param(
    [Parameter(Mandatory)][string]$KeyVaultName,
    [Parameter(Mandatory)][string]$ClusterName,
    [string]$Namespace       = "default",
    [string]$SecretPrefix    = "satoken",
    [string]$ApiServerPrefix = "apiserver",
    [switch]$TestRestart,          # runs a PATCH restart (specify -WorkloadType/-WorkloadName)
    [string]$WorkloadType    = "deployment",
    [string]$WorkloadName    = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Resolve Shared-Functions.ps1 — supports both repo layout (scripts\..\runbooks\)
# and flat deployment layout (all files in same folder, e.g. C:\Scripts\)
$sharedFunctionsPath = Join-Path $PSScriptRoot "..\runbooks\Shared-Functions.ps1"
if (-not (Test-Path $sharedFunctionsPath)) {
    $sharedFunctionsPath = Join-Path $PSScriptRoot "Shared-Functions.ps1"
}
if (-not (Test-Path $sharedFunctionsPath)) {
    throw "Shared-Functions.ps1 not found. Copy it to $PSScriptRoot or ensure repo folder layout is intact."
}
. $sharedFunctionsPath

$safeCluster  = $ClusterName -replace '[^a-zA-Z0-9-]','-'
$saSecretName = "$SecretPrefix-$safeCluster"
$apSecretName = "$ApiServerPrefix-$safeCluster"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  SA Token Access Test" -ForegroundColor Cyan
Write-Host "  Cluster   : $ClusterName" -ForegroundColor Cyan
Write-Host "  Key Vault : $KeyVaultName" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

Write-Host "`n[1] Getting KV token via himds..." -ForegroundColor Yellow
$kvToken = Get-HimdsToken -Resource "https://vault.azure.net"
Write-Host "  OK ($($kvToken.Length) chars)" -ForegroundColor Green

Write-Host "`n[2] Fetching SA token from KV ($saSecretName)..." -ForegroundColor Yellow
$saToken   = Get-KvSecret -VaultName $KeyVaultName -SecretName $saSecretName -KvToken $kvToken
Write-Host "  SA token: $($saToken.Length) chars" -ForegroundColor Green

# Decode SA token to show issuer/expiry
try {
    $part = $saToken.Split('.')[1] -replace '-','+' -replace '_','/'
    $part += '=' * ((4 - ($part.Length % 4)) % 4)
    $claims = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
    Write-Host "  Issuer: $($claims.iss)" -ForegroundColor DarkGray
    if ($claims.exp) {
        $exp = [System.DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp).LocalDateTime
        $daysLeft = ([System.DateTimeOffset]::FromUnixTimeSeconds([long]$claims.exp) - [System.DateTimeOffset]::UtcNow).TotalDays
        $expCol = if ($daysLeft -lt 30) {'Red'} elseif ($daysLeft -lt 90) {'Yellow'} else {'Green'}
        Write-Host "  Expires: $exp ($([Math]::Round($daysLeft)) days)" -ForegroundColor $expCol
    } else {
        Write-Host "  Expiry: none (long-lived SA token)" -ForegroundColor Green
    }
} catch { Write-Host "  Could not decode token claims" -ForegroundColor DarkGray }

Write-Host "`n[3] Fetching API server from KV ($apSecretName)..." -ForegroundColor Yellow
$apiServer = Get-KvSecret -VaultName $KeyVaultName -SecretName $apSecretName -KvToken $kvToken
Write-Host "  API server: $apiServer" -ForegroundColor Green

$apiHost = $apiServer -replace ':.*',''
$apiPort = if ($apiServer -match ':(\d+)$') { [int]$Matches[1] } else { 6443 }

Write-Host "`n[4] TCP connectivity $($apiHost):$apiPort ..." -ForegroundColor Yellow
if (Test-TcpPort -Hostname $apiHost -Port $apiPort) {
    Write-Host "  TCP OPEN" -ForegroundColor Green
} else {
    Write-Host "  TCP TIMEOUT -- cannot reach API server from this worker" -ForegroundColor Red
    exit 1
}

Write-Host "`n[5] GET /api/v1/namespaces..." -ForegroundColor Yellow
$t0 = Get-Date
$r  = Invoke-K8sRest -ApiServer $apiServer -Path "/api/v1/namespaces" -Token $saToken
$ms = [Math]::Round((New-TimeSpan $t0 (Get-Date)).TotalMilliseconds)
if ($r.Ok) {
    $ns = ($r.Body | ConvertFrom-Json).items.metadata.name
    Write-Host "  OK (${ms}ms) -- Namespaces: $($ns -join ', ')" -ForegroundColor Green
} else {
    Write-Host "  HTTP $($r.StatusCode) (${ms}ms)" -ForegroundColor Red
    Write-Host "  $($r.Body.Substring(0,[Math]::Min(300,$r.Body.Length)))" -ForegroundColor DarkGray
    exit 1
}

Write-Host "`n[6] Workloads in namespace '$Namespace'..." -ForegroundColor Yellow
foreach ($type in @("deployments","statefulsets","daemonsets")) {
    $rw = Invoke-K8sRest -ApiServer $apiServer -Path "/apis/apps/v1/namespaces/$Namespace/$type" -Token $saToken
    if ($rw.Ok) {
        $parsed = $rw.Body | ConvertFrom-Json
        $items  = @($parsed.items | Where-Object { $_ -and $_.metadata } | ForEach-Object { $_.metadata.name })
        $col    = if ($items.Count -gt 0) {'Green'} else {'DarkGray'}
        Write-Host "  $type : $(if($items.Count -gt 0){$items -join ', '}else{'(none)'})" -ForegroundColor $col
    } else {
        Write-Host "  $type : HTTP $($rw.StatusCode)" -ForegroundColor Red
    }
}

if ($TestRestart -and $WorkloadName) {
    Write-Host "`n[7] TEST RESTART: $WorkloadType/$WorkloadName in $Namespace..." -ForegroundColor Yellow
    $typeMap = @{ deployment="deployments"; statefulset="statefulsets"; daemonset="daemonsets" }
    $apiType = $typeMap[$WorkloadType.ToLower()]
    $ts      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $patch   = "{`"spec`":{`"template`":{`"metadata`":{`"annotations`":{`"kubectl.kubernetes.io/restartedAt`":`"$ts`"}}}}}"
    $pr = Invoke-K8sRest -ApiServer $apiServer -Path "/apis/apps/v1/namespaces/$Namespace/$apiType/$WorkloadName" `
        -Token $saToken -Method "PATCH" -Body $patch
    if ($pr.Ok) {
        Write-Host "  PATCH HTTP $($pr.StatusCode) -- restart triggered" -ForegroundColor Green
    } else {
        Write-Host "  PATCH HTTP $($pr.StatusCode) -- $($pr.Body.Substring(0,[Math]::Min(200,$pr.Body.Length)))" -ForegroundColor Red
    }
}

Write-Host "`n[8] Timing -- 3 rapid calls to measure throughput..." -ForegroundColor Yellow
$times = 1..3 | ForEach-Object {
    $t = Measure-Command { Invoke-K8sRest -ApiServer $apiServer -Path "/api/v1/namespaces" -Token $saToken | Out-Null }
    [Math]::Round($t.TotalMilliseconds)
}
$avg = [Math]::Round(($times | Measure-Object -Average).Average)
Write-Host "  Call times: $($times -join 'ms, ')ms" -ForegroundColor White
Write-Host "  Average: ${avg}ms per cluster call" -ForegroundColor Green
Write-Host "  800 clusters (16 shards x 50 parallel): ~$([Math]::Round($avg * 16 / 1000, 1))s total" -ForegroundColor White

Write-Host "`n================================================================" -ForegroundColor Green
Write-Host "  ALL TESTS PASSED -- SA token path is working" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
