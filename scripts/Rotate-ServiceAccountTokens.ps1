#Requires -Version 5.1
# Rotate-ServiceAccountTokens.ps1
# PURPOSE : Annual token rotation. Deletes and recreates the K8s SA Secret on
#           each cluster to generate a fresh token, then updates Key Vault.
#           Previous KV secret version is retained for rollback (7-day soft delete).
# RUN ON  : HCI host or jump box with admin kubeconfig access
# SCHEDULE: Run annually via Azure Automation schedule

param(
    [Parameter(Mandatory)][string]$KeyVaultName,
    [string]$ClusterName    = "",      # single cluster, or leave blank for all
    [switch]$AutoDiscover,             # discover all clusters via Get-AksHciCluster
    [string]$KubeconfigPath = "",      # for single cluster
    [string]$SecretPrefix   = "satoken",
    [int]   $ParallelJobs   = 5,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "..\runbooks\Shared-Functions.ps1")

$kube = Get-Command kubectl -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $kube) {
    foreach ($c in @("C:\tools\kubectl.exe","C:\kubectl\kubectl.exe")) {
        if (Test-Path $c) { $kube = $c; break }
    }
}
if (-not $kube) { throw "kubectl not found" }

$kvToken = Get-HimdsToken -Resource "https://vault.azure.net"

$clusters = [System.Collections.Generic.List[PSCustomObject]]::new()
if ($AutoDiscover) {
    foreach ($c in (Get-AksHciCluster)) {
        $tmpKube = "$env:TEMP\kube-$($c.Name)-rotate.yaml"
        Get-AksHciCredential -Name $c.Name -Confirm:$false
        Copy-Item "$env:USERPROFILE\.kube\config" $tmpKube -Force
        Remove-Item "$env:USERPROFILE\.kube\config" -Force -ErrorAction SilentlyContinue
        $clusters.Add([PSCustomObject]@{ Name=$c.Name; Kubeconfig=$tmpKube })
    }
} else {
    if (-not (Test-Path $KubeconfigPath)) { throw "Kubeconfig not found: $KubeconfigPath" }
    $clusters.Add([PSCustomObject]@{ Name=$ClusterName; Kubeconfig=$KubeconfigPath })
}

Write-Host "Rotating SA tokens for $($clusters.Count) cluster(s)..." -ForegroundColor Cyan

$results = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

$clusters | ForEach-Object -ThrottleLimit $ParallelJobs -Parallel {
    $c       = $_
    $kube    = $using:kube
    $kvName  = $using:KeyVaultName
    $kvToken = $using:kvToken
    $spfx    = $using:SecretPrefix
    $wi      = $using:WhatIf
    $bag     = $using:results

    $r = [PSCustomObject]@{ Cluster=$c.Name; Status="Unknown"; Error="" }
    try {
        if ($wi) {
            Write-Host "[$($c.Name)] WHATIF -- would delete secret and re-extract token" -ForegroundColor DarkYellow
            $r.Status = "WhatIf"; $bag.Add($r); return
        }

        # Delete old Secret (K8s regenerates automatically when re-applied)
        Write-Host "[$($c.Name)] Deleting old SA Secret..." -ForegroundColor Yellow
        & $kube delete secret automation-restart-token -n kube-system --kubeconfig $c.Kubeconfig `
            --ignore-not-found 2>&1 | Out-Null

        # Re-apply SA manifest (recreates Secret)
        $saYaml = Join-Path $PSScriptRoot "..\k8s\restart-sa.yaml"
        & $kube apply -f $saYaml --kubeconfig $c.Kubeconfig 2>&1 | Out-Null

        # Wait for new token
        $token = $null
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 2
            $secretJson = & $kube get secret automation-restart-token -n kube-system `
                -o json --kubeconfig $c.Kubeconfig 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                $obj = $secretJson | ConvertFrom-Json
                $b64 = $obj.data.token
                if ($b64) {
                    $token = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
                    break
                }
            }
        }
        if (-not $token) { throw "New token not generated after 30s" }

        # Update Key Vault (creates new version, old version retained)
        $secretName = "$spfx-$($c.Name -replace '[^a-zA-Z0-9-]','-')"
        $uri = "https://$kvName.vault.azure.net/secrets/$secretName`?api-version=7.4"
        Invoke-RestMethod -Uri $uri -Method PUT `
            -Headers @{ Authorization="Bearer $kvToken"; "Content-Type"="application/json" } `
            -Body (@{
                value = $token
                attributes = @{ enabled=$true }
                tags = @{ cluster=$c.Name; type="sa-token"; rotated=(Get-Date -Format 'yyyy-MM-dd') }
            } | ConvertTo-Json) | Out-Null

        Write-Host "[$($c.Name)] Token rotated and KV updated" -ForegroundColor Green
        $r.Status = "Success"
    } catch {
        $r.Status = "Failed"; $r.Error = $_.Exception.Message
        Write-Host "[$($c.Name)] FAILED: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        if ($c.Kubeconfig -match 'kube-.*-rotate\.yaml$') {
            Remove-Item $c.Kubeconfig -Force -ErrorAction SilentlyContinue
        }
        $bag.Add($r)
    }
}

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host "  ROTATION SUMMARY" -ForegroundColor Cyan
$results | Sort-Object Cluster | Format-Table Cluster, Status, Error -AutoSize
$failed = @($results | Where-Object Status -eq "Failed")
if ($failed.Count -gt 0) { exit 1 }
Write-Host "Rotation complete. Previous KV versions retained for 7-day rollback." -ForegroundColor Green
