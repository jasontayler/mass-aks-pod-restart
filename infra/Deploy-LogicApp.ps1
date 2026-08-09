#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys the optional Logic App HTTP trigger for the SA Token Pattern.

.DESCRIPTION
    Reads infra-state.json (written by Deploy-Infrastructure.ps1), then:
      1. Deploys logic-app/logicapp-template.json into the same resource group.
         The Logic App uses a System-Assigned Managed Identity and calls the
         Azure Automation REST API directly — no connector or manual portal
         authorisation step required.
      2. Assigns the 'Automation Operator' role to the Logic App's system MI
         on the Automation Account, so it can create and read jobs.
      3. Outputs the HTTPS trigger URL and writes logic-app-state.json.

.PARAMETER LogicAppName
    Name for the Logic App resource. Defaults to 'logic-aksarc-restart-trigger'.

.PARAMETER StateFile
    Path to infra-state.json. Defaults to the folder containing this script.

.EXAMPLE
    # Deploy with defaults (reads infra-state.json from same folder):
    .\Deploy-LogicApp.ps1

    # Custom Logic App name:
    .\Deploy-LogicApp.ps1 -LogicAppName "logic-aksarc-restart-prod"
#>

param(
    [string]$LogicAppName = "logic-aksarc-restart-trigger",
    [string]$StateFile    = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Read infra-state.json
# ---------------------------------------------------------------------------
if (-not $StateFile) { $StateFile = Join-Path $PSScriptRoot "infra-state.json" }
if (-not (Test-Path $StateFile)) {
    throw "infra-state.json not found at '$StateFile'. Run Deploy-Infrastructure.ps1 first."
}

$state          = Get-Content $StateFile -Raw | ConvertFrom-Json
$subscriptionId = $state.SubscriptionId
$resourceGroup  = $state.ResourceGroup
$location       = $state.Location
$automationName = $state.AutomationAccountName

$templateFile = Join-Path $PSScriptRoot "..\logic-app\logicapp-template.json"
if (-not (Test-Path $templateFile)) {
    throw "logicapp-template.json not found at '$templateFile'."
}

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  SA Token Pattern - Logic App Deploy" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

$ctx = Get-AzContext -ErrorAction SilentlyContinue
if (-not $ctx -or $ctx.Subscription.Id -ne $subscriptionId) {
    Connect-AzAccount -Subscription $subscriptionId -ErrorAction Stop | Out-Null
}
Set-AzContext -SubscriptionId $subscriptionId -ErrorAction Stop | Out-Null
Write-Host "  Subscription : $((Get-AzContext).Subscription.Name)" -ForegroundColor Green
Write-Host "  Resource Grp : $resourceGroup"
Write-Host "  Automation   : $automationName"
Write-Host "  Logic App    : $LogicAppName"
Write-Host ""

# ---------------------------------------------------------------------------
# Step 1 — Deploy ARM template
# ---------------------------------------------------------------------------
Write-Host "[1/2] Deploying Logic App ARM template..." -ForegroundColor Cyan

$deployParams = @{
    logicAppName                    = $LogicAppName
    automationAccountName           = $automationName
    automationAccountResourceGroup  = $resourceGroup
    automationAccountSubscriptionId = $subscriptionId
}

$deployName = "la-deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$deployment = New-AzResourceGroupDeployment `
    -Name                    $deployName `
    -ResourceGroupName       $resourceGroup `
    -TemplateFile            $templateFile `
    -TemplateParameterObject $deployParams `
    -ErrorAction             Stop

$triggerUrl  = $deployment.Outputs["logicAppTriggerUrl"].Value
$principalId = $deployment.Outputs["logicAppPrincipalId"].Value

Write-Host "  Logic App deployed" -ForegroundColor Green
Write-Host "  System MI Principal ID: $principalId"

# ---------------------------------------------------------------------------
# Step 2 — Assign Automation Operator to Logic App MI
#           Allows the Logic App to PUT/GET jobs on the Automation Account.
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[2/2] Assigning Automation Operator role to Logic App MI..." -ForegroundColor Cyan

$aaResourceId         = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Automation/automationAccounts/$automationName"
$automationOperRoleId = 'd3881f73-407a-4167-8283-e981cbba0404'

$existing = Get-AzRoleAssignment `
    -ObjectId         $principalId `
    -RoleDefinitionId $automationOperRoleId `
    -Scope            $aaResourceId `
    -ErrorAction      SilentlyContinue

if ($existing) {
    Write-Host "  Role already assigned (skipped)" -ForegroundColor DarkGray
} else {
    # The system-assigned MI principal may not have fully replicated in AAD yet
    # immediately after the ARM deployment. Retry with backoff (up to ~2 min).
    $maxAttempts = 8
    $attempt     = 0
    $assigned    = $false
    while (-not $assigned -and $attempt -lt $maxAttempts) {
        $attempt++
        try {
            New-AzRoleAssignment `
                -ObjectId         $principalId `
                -RoleDefinitionId $automationOperRoleId `
                -Scope            $aaResourceId `
                -ErrorAction      Stop | Out-Null
            $assigned = $true
            Write-Host "  Role assigned: Automation Operator (attempt $attempt)" -ForegroundColor Green
        } catch {
            $msg = $_.Exception.Message
            if ($attempt -lt $maxAttempts -and ($msg -match 'BadRequest|PrincipalNotFound|does not exist')) {
                $wait = $attempt * 15
                Write-Host "  AAD principal not yet propagated. Waiting ${wait}s (attempt $attempt/$maxAttempts)..." -ForegroundColor Yellow
                Start-Sleep -Seconds $wait
            } else {
                throw
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Write logic-app-state.json (next to infra-state.json)
# ---------------------------------------------------------------------------
$laStateFile = Join-Path $PSScriptRoot "logic-app-state.json"
@{
    SubscriptionId        = $subscriptionId
    ResourceGroup         = $resourceGroup
    LogicAppName          = $LogicAppName
    LogicAppPrincipalId   = $principalId
    AutomationAccountName = $automationName
    TriggerUrl            = $triggerUrl
    DeployedAt            = (Get-Date).ToString("o")
} | ConvertTo-Json | Set-Content $laStateFile

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  LOGIC APP DEPLOYED" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  Logic App     : $LogicAppName" -ForegroundColor White
Write-Host "  Principal ID  : $principalId" -ForegroundColor White
Write-Host "  State file    : $laStateFile" -ForegroundColor White
Write-Host ""
Write-Host "  TRIGGER URL (treat as a secret - share via Key Vault or APIM):" -ForegroundColor Yellow
Write-Host "  $triggerUrl" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Example request:" -ForegroundColor Yellow
Write-Host "    curl -X POST '<trigger-url>'" -ForegroundColor DarkGray
Write-Host "      -H 'Content-Type: application/json'" -ForegroundColor DarkGray
Write-Host "      -d '{""namespace"":""production"",""workloadType"":""statefulset"",""workloadName"":""my-app"",""initiatedBy"":""your-name""}'" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Response includes: jobGuid, jobStatus, jobStartTime, jobEndTime, output" -ForegroundColor DarkGray
Write-Host "================================================================" -ForegroundColor Green
