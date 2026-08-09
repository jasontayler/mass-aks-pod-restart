#Requires -Version 5.1
# Cleanup-AzureResources.ps1
# PURPOSE : Removes Azure resources created in the previous approach
#           (ARM proxy / Azure RBAC approach) for a clean slate.
#           Does NOT delete the Key Vault (soft-delete protects secrets).
#           Does NOT delete Arc-connected clusters or HCI infrastructure.
#
# REVIEW the $resourcesToDelete list before running.
# Use -WhatIf first to preview what will be removed.
#
# RUN ON : Any machine with az CLI and Owner on the subscription
# USAGE  :
#   .\Cleanup-AzureResources.ps1 -SubscriptionId "e858a6b1-..." -WhatIf
#   .\Cleanup-AzureResources.ps1 -SubscriptionId "e858a6b1-..." -Confirm

param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ResourceGroup       = "azlocaliac-use",    # existing RG with old resources
    [string]$AutomationAccount   = "",                  # leave blank to skip AA deletion
    [string]$OldKeyVaultName     = "",                  # leave blank to skip KV deletion
    [switch]$RemoveRoleAssignments,                     # removes RBAC assignments for old MI OID
    [string]$OldMiOid            = "fb6fa291-3d35-4389-aa54-90609519eff4",
    [switch]$WhatIf,
    [switch]$Confirm
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

if (-not $WhatIf -and -not $Confirm) {
    Write-Host "Use -WhatIf to preview or -Confirm to execute." -ForegroundColor Yellow
    exit 0
}

$az = Get-Command az -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $az) { throw "az CLI not found" }

az account set --subscription $SubscriptionId

function Do-Action {
    param([string]$Label, [scriptblock]$Cmd)
    if ($WhatIf) {
        Write-Host "WHATIF: $Label" -ForegroundColor DarkYellow
    } else {
        Write-Host "Removing: $Label" -ForegroundColor Yellow
        & $Cmd 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Done" -ForegroundColor Green
        } else {
            Write-Host "  Warning: command returned non-zero (may already be removed)" -ForegroundColor DarkYellow
        }
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  CLEANUP PREVIEW (sub: $SubscriptionId)" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

# 1. Role assignments on old MI OID
if ($RemoveRoleAssignments -and $OldMiOid) {
    Write-Host "`n[1] Removing role assignments for OID $OldMiOid..." -ForegroundColor Yellow
    $assignments = az role assignment list --assignee $OldMiOid --subscription $SubscriptionId -o json 2>$null | ConvertFrom-Json
    if ($assignments) {
        foreach ($a in $assignments) {
            Do-Action "Role '$($a.roleDefinitionName)' at $($a.scope)" {
                az role assignment delete --ids $a.id --yes
            }
        }
    } else {
        Write-Host "  No role assignments found for $OldMiOid" -ForegroundColor DarkGray
    }
}

# 2. Automation Account
if ($AutomationAccount) {
    Write-Host "`n[2] Automation Account: $AutomationAccount" -ForegroundColor Yellow
    Do-Action "Delete Automation Account $AutomationAccount" {
        az automation account delete -g $ResourceGroup -n $AutomationAccount --yes
    }
}

# 3. Key Vault (only if explicitly specified -- soft delete retains secrets 7 days)
if ($OldKeyVaultName) {
    Write-Host "`n[3] Key Vault: $OldKeyVaultName (soft-delete -- secrets retained 7 days)" -ForegroundColor Yellow
    Do-Action "Delete Key Vault $OldKeyVaultName" {
        az keyvault delete --name $OldKeyVaultName -g $ResourceGroup
    }
}

# 4. List remaining resources for review
Write-Host "`n[4] Remaining resources in RG $ResourceGroup (for review):" -ForegroundColor Cyan
az resource list -g $ResourceGroup --query "[].{Name:name, Type:type, Location:location}" -o table 2>$null

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
if ($WhatIf) {
    Write-Host "  WHATIF complete -- nothing was deleted." -ForegroundColor Yellow
    Write-Host "  Re-run with -Confirm to execute." -ForegroundColor White
} else {
    Write-Host "  CLEANUP complete." -ForegroundColor Green
    Write-Host "  Next: run SA-Token-Pattern\infra\Deploy-Infrastructure.ps1" -ForegroundColor White
}
Write-Host "================================================================" -ForegroundColor Cyan
