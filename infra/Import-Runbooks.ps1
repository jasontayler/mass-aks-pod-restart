#Requires -Version 5.1
<#
.SYNOPSIS
    Imports and publishes all runbooks into the Azure Automation Account.

.DESCRIPTION
    Uploads Worker-RestartSingleCluster, Shard-RestartPods, Master-FleetRestart
    and Shared-Functions as published runbooks.

    Runbook types:
      Master-FleetRestart        -- PowerShell 5.1 (cloud, no -Parallel needed)
      Shard-RestartPods          -- PowerShell 7.2 (Hybrid Worker, uses -Parallel)
      Worker-RestartSingleCluster-- PowerShell 7.2 (Hybrid Worker)
      Shared-Functions           -- PowerShell 5.1 (library, dot-sourced from C:\Scripts\)

    NOTE: Shared-Functions is also deployed to C:\Scripts\ on the Hybrid Worker
    so runbooks can dot-source it at runtime.

.EXAMPLE
    .\Import-Runbooks.ps1 -SubscriptionId "e858a6b1-..." -ResourceGroup "RG-LogicApp-Mass-Pod-Restart" -AutomationName "aa-aks-pod-restart"
#>

param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$AutomationName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Import Runbooks -> $AutomationName" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# Auth
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx -or $ctx.Subscription.Id -ne $SubscriptionId) {
    Connect-AzAccount -Subscription $SubscriptionId | Out-Null
}
Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
Write-Host "Subscription: $((Get-AzContext).Subscription.Name)" -ForegroundColor Green

$runbooksDir = Join-Path $PSScriptRoot "..\runbooks"

# Runbook definitions: Name, file, type, description
$runbooks = @(
    @{
        Name        = "Master-FleetRestart"
        File        = "Master-FleetRestart.ps1"
        Type        = "PowerShell"          # PS 5.1 -- cloud entry point
        Description = "Orchestrates fleet-wide pod/deployment restart. Discovers clusters via Resource Graph, shards to Hybrid Workers."
    },
    @{
        Name        = "Shard-RestartPods"
        File        = "Shard-RestartPods.ps1"
        Type        = "PowerShell72"        # PS 7.2 -- needs ForEach-Object -Parallel
        Description = "Parallel inner loop. Receives shard of clusters from Master, calls Worker for each."
    },
    @{
        Name        = "Worker-RestartSingleCluster"
        File        = "Worker-RestartSingleCluster.ps1"
        Type        = "PowerShell72"        # PS 7.2 -- runs on Hybrid Worker
        Description = "Single-cluster restart. Fetches SA token from KV, calls K8s API, writes audit log."
    },
    @{
        Name        = "Shared-Functions"
        File        = "Shared-Functions.ps1"
        Type        = "PowerShell"          # PS 5.1 library
        Description = "Shared function library: Get-HimdsToken, Get-KvSecret, Invoke-K8sRest, Write-AuditLog, Test-TcpPort."
    }
)

$imported = 0
$failed   = 0

foreach ($rb in $runbooks) {
    $filePath = Join-Path $runbooksDir $rb.File
    if (-not (Test-Path $filePath)) {
        Write-Host "  SKIP $($rb.Name) -- file not found: $filePath" -ForegroundColor Yellow
        continue
    }

    Write-Host ""
    Write-Host "  Importing: $($rb.Name) ($($rb.Type))..." -NoNewline

    try {
        # Import (creates or overwrites draft)
        Import-AzAutomationRunbook `
            -ResourceGroupName     $ResourceGroup `
            -AutomationAccountName $AutomationName `
            -Name                  $rb.Name `
            -Path                  $filePath `
            -Type                  $rb.Type `
            -Description           $rb.Description `
            -Force `
            -ErrorAction Stop | Out-Null

        # Publish (draft -> published)
        Publish-AzAutomationRunbook `
            -ResourceGroupName     $ResourceGroup `
            -AutomationAccountName $AutomationName `
            -Name                  $rb.Name `
            -ErrorAction Stop | Out-Null

        Write-Host " published" -ForegroundColor Green
        $imported++
    } catch {
        Write-Host " FAILED: $($_.Exception.Message)" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor $(if ($failed -eq 0){'Green'} else {'Yellow'})
Write-Host "  IMPORT COMPLETE: $imported published, $failed failed" -ForegroundColor $(if ($failed -eq 0){'Green'} else {'Yellow'})
Write-Host "================================================================" -ForegroundColor $(if ($failed -eq 0){'Green'} else {'Yellow'})

if ($failed -eq 0) {
    Write-Host ""
    Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "  1. Also copy runbooks to C:\Scripts\ on each Hybrid Worker:" -ForegroundColor White
    Write-Host "     Copy-Item '$runbooksDir\*.ps1' 'C:\Scripts\' on the worker VM" -ForegroundColor DarkGray
    Write-Host "  2. Test Master via Azure Portal -> Automation Account -> Runbooks -> Master-FleetRestart -> Start" -ForegroundColor White
    Write-Host "     Parameters: Namespace=kube-system  WorkloadType=deployment  WorkloadName=coredns" -ForegroundColor DarkGray
    Write-Host "  3. Check output in Jobs tab and Log Analytics (AKSArcRestart_CL table)" -ForegroundColor White
}
