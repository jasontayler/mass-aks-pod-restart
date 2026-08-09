#Requires -Version 5.1
<#
.SYNOPSIS
    Azure-side setup for Hybrid Worker Group.
    Run from any machine authenticated with az CLI (Owner on the subscription).
    Run AFTER Deploy-Infrastructure.ps1 (reads infra-state.json from same folder).

.DESCRIPTION
    Creates the Hybrid Worker Group in the Automation Account.
    Writes hybrid-worker-state.json for Register-HybridWorker-OnPrem.ps1.

    Run Register-HybridWorker-OnPrem.ps1 on each on-prem Windows machine
    that will act as a Hybrid Worker (network-adjacent to AKS Arc clusters).

.EXAMPLE
    .\Setup-HybridWorkerGroup.ps1
    .\Setup-HybridWorkerGroup.ps1 -WorkerResourceGroup "rg-aksarc-workers"
#>

param(
    [string]$WorkerResourceGroup = "",  # defaults to same RG as Automation Account
    [string]$WorkerLocation      = ""   # defaults to same location as Automation Account
)

$ErrorActionPreference = "Stop"

# -- Load state from Deploy-Infrastructure.ps1 --------------------------------
$stateFile = Join-Path $PSScriptRoot "infra-state.json"
if (-not (Test-Path $stateFile)) {
    throw "infra-state.json not found. Run Deploy-Infrastructure.ps1 first."
}
$state    = Get-Content $stateFile | ConvertFrom-Json
$sub      = $state.SubscriptionId
$tenantId = $state.TenantId
$rg       = $state.ResourceGroup
$aaName   = $state.AutomationAccountName
$aaMiOid  = $state.AutomationMiOid
$kvId     = $state.KeyVaultId
$hwGroup  = $state.HybridWorkerGroup
$location = if ($WorkerLocation)      { $WorkerLocation      } else { $state.Location }
$workerRg = if ($WorkerResourceGroup) { $WorkerResourceGroup } else { $rg }

az account set --subscription $sub

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Hybrid Worker Group Setup (Azure Side)"   -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Automation Account : $aaName"
Write-Host "  AA Resource Group  : $rg"
Write-Host "  Worker Group Name  : $hwGroup"
Write-Host "  Worker RG          : $workerRg"
Write-Host "  Worker Location    : $location"
Write-Host ""

$token = az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv
$hdrs  = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

# -- Get Automation Account registration URL ----------------------------------
Write-Host "[1/3] Getting Automation Account registration URL..." -NoNewline
$aaUri    = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg" +
            "/providers/Microsoft.Automation/automationAccounts/$aaName`?api-version=2023-11-01"
$aaDetail = Invoke-RestMethod -Uri $aaUri -Headers $hdrs
$aaUrl    = $aaDetail.properties.automationHybridServiceUrl
Write-Host " Done" -ForegroundColor Green

# -- Create Hybrid Worker Group -----------------------------------------------
Write-Host "[2/3] Creating Hybrid Worker Group '$hwGroup'..." -NoNewline
$groupUri  = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg" +
             "/providers/Microsoft.Automation/automationAccounts/$aaName" +
             "/hybridRunbookWorkerGroups/$hwGroup`?api-version=2022-08-08"
$groupBody = @{ properties = @{} } | ConvertTo-Json -Depth 5

try {
    Invoke-RestMethod -Uri $groupUri -Method PUT -Headers $hdrs -Body $groupBody | Out-Null
    Write-Host " Created" -ForegroundColor Green
} catch {
    if ($_.Exception.Message -match "already exists|Conflict|409") {
        Write-Host " Already exists" -ForegroundColor Yellow
    } else { throw }
}

# -- Ensure worker RG exists --------------------------------------------------
Write-Host "[3/3] Ensuring worker resource group '$workerRg' exists..." -NoNewline
az group create --name $workerRg --location $location --output none
Write-Host " OK" -ForegroundColor Green

# -- Save state for Register-HybridWorker-OnPrem.ps1 --------------------------
$hwStateFile = Join-Path $PSScriptRoot "hybrid-worker-state.json"
@{
    SubscriptionId        = $sub
    TenantId              = $tenantId
    AutomationAccountName = $aaName
    AutomationAccountUrl  = $aaUrl
    AutomationMiOid       = $aaMiOid
    WorkerGroupName       = $hwGroup
    WorkerResourceGroup   = $workerRg
    WorkerLocation        = $location
    KeyVaultId            = $kvId
} | ConvertTo-Json | Set-Content $hwStateFile

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Worker Group Ready"                       -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Automation Account URL : $aaUrl"
Write-Host ""
Write-Host "  NEXT: For each on-prem Windows machine that will be a Hybrid Worker:"
Write-Host ""
Write-Host "  1. Copy these two files to the machine:" -ForegroundColor Yellow
Write-Host "       infra\hybrid-worker-state.json" -ForegroundColor Cyan
Write-Host "       infra\Register-HybridWorker-OnPrem.ps1" -ForegroundColor Cyan
Write-Host ""
Write-Host "  2. On the machine (PowerShell as Administrator):" -ForegroundColor Yellow
Write-Host "       Set-ExecutionPolicy Bypass -Scope Process -Force" -ForegroundColor Cyan
Write-Host "       .\Register-HybridWorker-OnPrem.ps1" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Machine requirements:"
Write-Host "    - Windows Server 2016+ or Windows 10/11 (64-bit)"
Write-Host "    - PowerShell 5.1+"
Write-Host "    - .NET Framework 4.6.2+"
Write-Host "    - Outbound HTTPS (443) to Azure endpoints"
Write-Host "    - Local Admin rights"
Write-Host "    - Network access to AKS Arc cluster API servers (port 6443)"
