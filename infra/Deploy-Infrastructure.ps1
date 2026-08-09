#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys all Azure infrastructure for the SA Token Pattern using Bicep.
    Run once per Azure subscription that hosts the Automation Account.

.DESCRIPTION
    1. Validates prerequisites (az CLI, bicep, subscription access)
    2. Runs: az deployment group create --template-file main.bicep
       Deploys: Automation Account + MI, Key Vault, Log Analytics, role assignments
    3. Extracts Bicep outputs (MI OID, KV ID, Workspace ID/Key)
    4. Sets Automation Account variables (workspace key, KV name, etc.)
    5. Grants Reader on any additional cluster subscriptions
    6. Writes infra-state.json for Setup-HybridWorkerGroup.ps1

.PARAMETER WhatIf
    Runs 'az deployment group what-if' instead of actual deployment.
    Shows all changes without creating any resources.

.EXAMPLE
    # Dry run first
    .\Deploy-Infrastructure.ps1 `
        -SubscriptionId    "e858a6b1-b4df-4533-98bf-8af3688e5f01" `
        -ResourceGroup     "rg-aksarc-automation" `
        -Location          "australiaeast" `
        -AutomationName    "aa-aksarc-restart" `
        -KeyVaultName      "kv-aksarc-restart" `
        -WorkspaceName     "law-aksarc-restart" `
        -HybridWorkerGroup "AKSArcWorkers" `
        -WhatIf

    # Full deploy
    .\Deploy-Infrastructure.ps1 `
        -SubscriptionId    "e858a6b1-b4df-4533-98bf-8af3688e5f01" `
        -ResourceGroup     "rg-aksarc-automation" `
        -Location          "australiaeast" `
        -AutomationName    "aa-aksarc-restart" `
        -KeyVaultName      "kv-aksarc-restart" `
        -WorkspaceName     "law-aksarc-restart" `
        -HybridWorkerGroup "AKSArcWorkers" `
        -ManagedClusterSubs "e858a6b1-...,bbbb-cccc-..."
#>

param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter(Mandatory)][string]$Location,
    [Parameter(Mandatory)][string]$AutomationName,
    [Parameter(Mandatory)][string]$KeyVaultName,
    [Parameter(Mandatory)][string]$WorkspaceName,
    [Parameter(Mandatory)][string]$HybridWorkerGroup,
    [string]$ManagedClusterSubs = "",   # comma-separated additional subs with AKS Arc clusters
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  SA Token Pattern - Infrastructure Deploy" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "az CLI not found. Install from https://aka.ms/installazurecliwindows"
}

# Bicep: try to install/upgrade, but don't fail if az extension dir has permissions issues
Write-Host "[0/4] Checking bicep..." -NoNewline
$bicepExe = "$env:USERPROFILE\.azure\bin\bicep.exe"
if (Test-Path $bicepExe) {
    $bicepVer = & $bicepExe --version 2>&1
    Write-Host " $bicepVer (cached)" -ForegroundColor Green
} else {
    # Fallback: try az bicep install, ignore errors from broken extensions
    try { az bicep install 2>$null } catch {}
    Write-Host " installed" -ForegroundColor Green
}

# Ensure Az PowerShell module is available (used for AA variables + role assignments)
Write-Host "      Checking Az PowerShell module..." -NoNewline
if (-not (Get-Module -ListAvailable -Name Az.Automation -ErrorAction SilentlyContinue)) {
    Write-Host " installing Az.Automation..." -NoNewline
    Install-Module Az.Automation -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
}
Write-Host " OK" -ForegroundColor Green

Write-Host "      Setting subscription context: $SubscriptionId"
# Use Az PowerShell for auth — avoids az CLI extension crash from broken aksarc ext
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx -or $ctx.Subscription.Id -ne $SubscriptionId) {
    Connect-AzAccount -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
}
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
$ctx      = Get-AzContext
$tenantId = $ctx.Tenant.Id
Write-Host "      Tenant: $tenantId  Sub: $($ctx.Subscription.Name)" -ForegroundColor Green
Write-Host ""

$bicepFile = Join-Path $PSScriptRoot "main.bicep"
if (-not (Test-Path $bicepFile)) {
    throw "main.bicep not found at $bicepFile. Ensure it is in the same folder as this script."
}

# Pre-compile Bicep → ARM JSON using the explicit bicep.exe path.
# This avoids New-AzResourceGroupDeployment's PATH-based bicep search,
# which fails in elevated (admin) sessions where .azure\bin is not in PATH.
$armJsonFile = Join-Path $PSScriptRoot "main.compiled.json"
Write-Host "      Compiling Bicep to ARM JSON..." -NoNewline
& $bicepExe build $bicepFile --outfile $armJsonFile 2>&1 | Out-Null
if (-not (Test-Path $armJsonFile)) { throw "Bicep compile failed - check main.bicep for errors." }
Write-Host " done" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 1 — Bicep deployment (all resources via Az PowerShell — avoids broken az CLI extension)
# ---------------------------------------------------------------------------
Write-Host "[1/4] Bicep deployment" -ForegroundColor Cyan

# Ensure RG exists
Write-Host "  Ensuring resource group '$ResourceGroup' exists..."
$rg = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue
if (-not $rg) {
    New-AzResourceGroup -Name $ResourceGroup -Location $Location | Out-Null
    Write-Host "  Resource group created." -ForegroundColor Green
}

$deployParams = @{
    location              = $Location
    automationAccountName = $AutomationName
    keyVaultName          = $KeyVaultName
    workspaceName         = $WorkspaceName
    hybridWorkerGroup     = $HybridWorkerGroup
}

if ($WhatIf) {
    Write-Host "  Running what-if (no resources created)..." -ForegroundColor Yellow
    $wifResult = Get-AzResourceGroupDeploymentWhatIfResult `
        -ResourceGroupName       $ResourceGroup `
        -TemplateFile            $armJsonFile `
        -TemplateParameterObject $deployParams
    $wifResult.Changes | Format-Table ResourceId, ChangeType -AutoSize
    Write-Host "  What-if complete. Remove -WhatIf to deploy for real." -ForegroundColor Yellow
    return
}

Write-Host "  Deploying via New-AzResourceGroupDeployment (Automation Account creation takes 2-5 min)..."
Write-Host "  Watch Azure Portal -> Resource Groups -> $ResourceGroup -> Deployments for live status."

$deployName  = "aksarc-infra-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$deployment  = New-AzResourceGroupDeployment `
    -Name                    $deployName `
    -ResourceGroupName       $ResourceGroup `
    -TemplateFile            $armJsonFile `
    -TemplateParameterObject $deployParams `
    -ErrorAction             Stop

Write-Host "  Deployment succeeded: $deployName" -ForegroundColor Green

$outputs    = $deployment.Outputs
$aaMiOid    = $outputs["automationMiOid"].Value
$aaUrl      = $outputs["automationHybridServiceUrl"].Value
$kvId       = $outputs["keyVaultId"].Value
$wsId       = $outputs["workspaceId"].Value
$hwGroupOut = $outputs["hybridWorkerGroupName"].Value

Write-Host "  Automation MI OID : $aaMiOid" -ForegroundColor Green
Write-Host "  Key Vault ID      : $kvId"     -ForegroundColor Green
Write-Host "  Workspace ID      : $wsId"     -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 2 — Get Log Analytics workspace key (not available from Bicep outputs)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/4] Retrieving Log Analytics workspace key..." -ForegroundColor Cyan
# Use Az PS module — avoids az CLI extension noise
$wsKeys = Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $ResourceGroup -Name $WorkspaceName
$wsKey  = $wsKeys.PrimarySharedKey
Write-Host "  Workspace key retrieved" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 3 — Set Automation Account variables (Az PowerShell — avoids az extension requirement)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[3/4] Setting Automation Account variables..." -ForegroundColor Cyan

$aaVarDefs = [ordered]@{
    "AA-KeyVaultName"      = @{ value = $KeyVaultName;      encrypted = $false }
    "AA-WorkspaceId"       = @{ value = $wsId;              encrypted = $false }
    "AA-WorkspaceKey"      = @{ value = $wsKey;             encrypted = $true  }
    "AA-HybridWorkerGroup" = @{ value = $HybridWorkerGroup; encrypted = $false }
    "AA-SaTokenPrefix"     = @{ value = "satoken";          encrypted = $false }
    "AA-ApiServerPrefix"   = @{ value = "apiserver";        encrypted = $false }
    "AA-SubscriptionIds"   = @{
        value     = if ($ManagedClusterSubs) { $ManagedClusterSubs } else { $SubscriptionId }
        encrypted = $false
    }
    # Used by Master-FleetRestart.ps1 to construct the ARM polling URI for shard jobs
    "AA-AccountName"       = @{ value = $AutomationName; encrypted = $false }
    "AA-ResourceGroup"     = @{ value = $ResourceGroup;  encrypted = $false }
}

foreach ($entry in $aaVarDefs.GetEnumerator()) {
    Write-Host "  $($entry.Key)..." -NoNewline
    $varParams = @{
        ResourceGroupName     = $ResourceGroup
        AutomationAccountName = $AutomationName
        Name                  = $entry.Key
        Value                 = $entry.Value.value
        Encrypted             = $entry.Value.encrypted
    }
    $existing = Get-AzAutomationVariable -ResourceGroupName $ResourceGroup `
        -AutomationAccountName $AutomationName -Name $entry.Key -ErrorAction SilentlyContinue
    if ($existing) {
        Set-AzAutomationVariable @varParams | Out-Null
    } else {
        New-AzAutomationVariable @varParams | Out-Null
    }
    Write-Host " OK" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 4 — Reader on additional cluster subscriptions
# ---------------------------------------------------------------------------
if ($ManagedClusterSubs) {
    Write-Host ""
    Write-Host "[4/4] Granting Reader on additional cluster subscriptions..." -ForegroundColor Cyan
    $clusterSubs = $ManagedClusterSubs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne $SubscriptionId }
    foreach ($cs in $clusterSubs) {
        Write-Host "  Reader on sub $cs -> Automation MI..." -NoNewline
        $readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
        $existing = Get-AzRoleAssignment -ObjectId $aaMiOid `
            -RoleDefinitionId $readerRoleId `
            -Scope "/subscriptions/$cs" -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-AzRoleAssignment -ObjectId $aaMiOid `
                -RoleDefinitionId $readerRoleId `
                -Scope "/subscriptions/$cs" | Out-Null
        }
        Write-Host " OK" -ForegroundColor Green
    }
} else {
    Write-Host ""
    Write-Host "[4/4] No additional cluster subscriptions specified (skipped)" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Write infra-state.json
# ---------------------------------------------------------------------------
$stateFile = Join-Path $PSScriptRoot "infra-state.json"
@{
    SubscriptionId        = $SubscriptionId
    TenantId              = $tenantId
    ResourceGroup         = $ResourceGroup
    Location              = $Location
    AutomationAccountName = $AutomationName
    AutomationMiOid       = $aaMiOid
    AutomationAccountUrl  = $aaUrl
    KeyVaultName          = $KeyVaultName
    KeyVaultId            = $kvId
    WorkspaceName         = $WorkspaceName
    WorkspaceId           = $wsId
    HybridWorkerGroup     = $hwGroupOut
} | ConvertTo-Json | Set-Content $stateFile

# Clean up compiled ARM JSON (temp artifact)
if (Test-Path $armJsonFile) { Remove-Item $armJsonFile -Force }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Automation Account : $AutomationName" -ForegroundColor White
Write-Host "  Automation MI OID  : $aaMiOid"        -ForegroundColor White
Write-Host "  Key Vault          : $KeyVaultName"    -ForegroundColor White
Write-Host "  Log Analytics      : $WorkspaceName ($wsId)" -ForegroundColor White
Write-Host "  State file         : $stateFile"       -ForegroundColor White
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
Write-Host "  1. Run infra\Setup-HybridWorkerGroup.ps1    (reads infra-state.json)" -ForegroundColor White
Write-Host "  2. Copy infra-state.json + Register-HybridWorker-OnPrem.ps1 to each" -ForegroundColor White
Write-Host "     on-prem machine and run it as Administrator" -ForegroundColor White
Write-Host "  3. Run scripts\Bootstrap-ServiceAccount.ps1 from HCI host" -ForegroundColor White
Write-Host "  4. Import runbooks from runbooks\ into $AutomationName" -ForegroundColor White
Write-Host "  5. Test with scripts\Test-SATokenAccess.ps1" -ForegroundColor White
Write-Host "  6. (Optional) Run infra\Deploy-LogicApp.ps1 for HTTP trigger UI" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor Green
