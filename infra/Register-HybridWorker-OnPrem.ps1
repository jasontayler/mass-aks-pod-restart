#Requires -Version 5.1
<#
.SYNOPSIS
    On-prem portion of Hybrid Worker registration.
    Run ON the on-prem Windows machine as local Administrator.
    Copy BOTH this script AND hybrid-worker-state.json to the same folder first.

.DESCRIPTION
    1. Installs the Azure Connected Machine agent (Arc agent) if not present
    2. Connects this machine to Azure Arc
    3. Pre-registers the machine in the Hybrid Worker Group (required before extension)
    4. Installs the HybridWorkerForWindows extension via ARM
    5. Grants the machine's Arc managed identity "Key Vault Secrets User" on the KV
    6. Installs PowerShell 7 (MSI, not winget) and Az.Accounts + Az.Resources for PS7

    The machine's Arc system-assigned managed identity is used by runbooks to:
      - Fetch SA tokens and API server addresses from Key Vault
      - Call each cluster's Kubernetes REST API directly

.NOTES
    Outbound 443 required to:
      download.microsoft.com, aka.ms
      login.microsoftonline.com, management.azure.com
      *.his.arc.azure.com, *.guestconfiguration.azure.com
      *.azure-automation.net

    NO inbound ports required.

.EXAMPLE
    .\Register-HybridWorker-OnPrem.ps1
    .\Register-HybridWorker-OnPrem.ps1 -MachineName "hw-node01"
#>

param(
    [string]$MachineName = ""   # defaults to $env:COMPUTERNAME
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Invoke-RestMethod on PS5.1/Windows Server can ignore ServicePointManager and default to TLS 1.0.
# Use HttpWebRequest directly (proven to work on this platform).
function Invoke-ArmRequest {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method    = "GET",
        [string]$Token,
        [string]$Body      = ""
    )
    $req = [System.Net.HttpWebRequest]::Create($Uri)
    $req.Method  = $Method
    if ($Token) { $req.Headers.Add("Authorization", "Bearer $Token") }
    $req.ContentType = "application/json"
    $req.Accept      = "application/json"
    if ($Body) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream()
        $s.Write($bytes, 0, $bytes.Length)
        $s.Close()
    } else {
        $req.ContentLength = 0
    }
    try {
        $resp = $req.GetResponse()
        $sr   = [System.IO.StreamReader]::new($resp.GetResponseStream())
        $json = $sr.ReadToEnd()
        $sr.Close(); $resp.Close()
        if ($json) { return $json | ConvertFrom-Json }
    } catch [System.Net.WebException] {
        $code = [int]$_.Exception.Response.StatusCode
        if ($code -eq 409) { throw "409 Conflict" }
        $errStream = $_.Exception.Response.GetResponseStream()
        $errBody   = [System.IO.StreamReader]::new($errStream).ReadToEnd()
        throw "HTTP $code : $errBody"
    }
}

# -- Admin check --------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Run as Administrator. Right-click PowerShell -> Run as Administrator."
}

# -- Load state ---------------------------------------------------------------
$stateFile = Join-Path $PSScriptRoot "hybrid-worker-state.json"
if (-not (Test-Path $stateFile)) {
    throw "hybrid-worker-state.json not found. Run infra\Setup-HybridWorkerGroup.ps1 first, then copy both files here."
}
$s = Get-Content $stateFile | ConvertFrom-Json
foreach ($field in @("SubscriptionId","TenantId","AutomationAccountName","AutomationAccountUrl",
                      "WorkerGroupName","WorkerResourceGroup","WorkerLocation","KeyVaultId")) {
    if (-not $s.$field) {
        throw "hybrid-worker-state.json missing field '$field'. Re-run Setup-HybridWorkerGroup.ps1."
    }
}

$sub      = $s.SubscriptionId
$tenantId = $s.TenantId
$aaName   = $s.AutomationAccountName
$aaUrl    = $s.AutomationAccountUrl
$hwGroup  = $s.WorkerGroupName
$workerRg = $s.WorkerResourceGroup
$workerLoc= $s.WorkerLocation
$kvId     = $s.KeyVaultId

if (-not $MachineName) { $MachineName = $env:COMPUTERNAME }

Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Extension-based Hybrid Worker Registration"     -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Machine            : $MachineName"
Write-Host "  Automation Account : $aaName"
Write-Host "  Worker Group       : $hwGroup"
Write-Host "  Arc Resource Group : $workerRg"
Write-Host "  Arc Location       : $workerLoc"
Write-Host "  Key Vault Scope    : $kvId"
Write-Host ""

$azcmagent = "${env:ProgramFiles}\AzureConnectedMachineAgent\azcmagent.exe"

# ===========================================================================
# STEP 1: Install Azure Connected Machine agent
# ===========================================================================
Write-Host "[1/6] Installing Azure Connected Machine agent..." -ForegroundColor Yellow

if (Test-Path $azcmagent) {
    $ver = & $azcmagent version 2>&1
    Write-Host "  Already installed: $ver" -ForegroundColor Green
} else {
    Write-Host "  Downloading Arc agent installer (~60MB)..." -NoNewline
    $installer = "$env:TEMP\install_windows_azcmagent.ps1"
    Invoke-WebRequest -Uri "https://aka.ms/azcmagent-windows" -OutFile $installer -UseBasicParsing
    Write-Host " Done"
    Write-Host "  Installing (silent)..." -NoNewline
    & powershell.exe -ExecutionPolicy Bypass -File $installer
    if ($LASTEXITCODE -ne 0) { throw "Arc agent installer failed (exit $LASTEXITCODE)" }
    Write-Host " Done" -ForegroundColor Green
}

# ===========================================================================
# STEP 2: Connect machine to Azure Arc
# ===========================================================================
Write-Host ""
Write-Host "[2/6] Connecting machine to Azure Arc..." -ForegroundColor Yellow

$statusOutput = & $azcmagent show 2>&1
$alreadyConnected = ($statusOutput | Where-Object { $_ -match 'Agent Status\s*:\s*Connected' }) -ne $null

if ($alreadyConnected) {
    Write-Host "  Already connected to Azure Arc" -ForegroundColor Green
} else {
    # Try az CLI token for non-interactive connect (available on machines with az installed)
    $connectToken = $null
    try { $connectToken = az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv 2>$null } catch { }

    if ($connectToken -and $connectToken.Length -gt 100) {
        Write-Host "  Using az CLI token (non-interactive)..."
        & $azcmagent connect `
            "--tenant-id"       $tenantId `
            "--subscription-id" $sub `
            "--resource-group"  $workerRg `
            "--location"        $workerLoc `
            "--resource-name"   $MachineName `
            "--access-token"    $connectToken
    } else {
        Write-Host "  az CLI token not available - device code auth required." -ForegroundColor Yellow
        Write-Host "  Sign in with an account that has 'Azure Connected Machine Onboarding' on RG: $workerRg" -ForegroundColor Cyan
        & $azcmagent connect `
            "--tenant-id"       $tenantId `
            "--subscription-id" $sub `
            "--resource-group"  $workerRg `
            "--location"        $workerLoc `
            "--resource-name"   $MachineName `
            "--use-device-code"
    }

    if ($LASTEXITCODE -ne 0) { throw "azcmagent connect failed (exit $LASTEXITCODE)" }
    Write-Host "  Arc connection successful" -ForegroundColor Green
}

# ===========================================================================
# STEP 3: Get ARM token (az CLI or Az module)
# ===========================================================================
Write-Host ""
Write-Host "[3/6] Getting ARM token for API calls..." -ForegroundColor Yellow

$armToken = $null
try { $armToken = az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv 2>$null } catch { }

if (-not $armToken -or $armToken.Length -lt 100) {
    Write-Host "  az CLI not available. Using Az PowerShell module..." -ForegroundColor Yellow
    if (-not (Get-Module -ListAvailable Az.Accounts -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        Install-Module Az.Accounts -Force -AllowClobber -Scope CurrentUser -Repository PSGallery | Out-Null
    }
    Import-Module Az.Accounts -Force
    Connect-AzAccount -UseDeviceAuthentication -TenantId $tenantId -Subscription $sub | Out-Null
    $rawToken = Get-AzAccessToken -ResourceUrl "https://management.azure.com/"
    $armToken = if ($rawToken.Token -is [securestring]) {
        [System.Net.NetworkCredential]::new('', $rawToken.Token).Password
    } else { [string]$rawToken.Token }
}

$hdrs = @{ Authorization = "Bearer $armToken"; "Content-Type" = "application/json" }
Write-Host "  Token acquired" -ForegroundColor Green

# ===========================================================================
# STEP 4: Pre-register machine in Hybrid Worker Group
# (Extension verifies pre-registration on startup)
# ===========================================================================
Write-Host ""
Write-Host "[4/6] Pre-registering machine in Hybrid Worker Group '$hwGroup'..." -ForegroundColor Yellow

$machineUri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$workerRg" +
              "/providers/Microsoft.HybridCompute/machines/$MachineName`?api-version=2022-11-10"
$machine    = Invoke-ArmRequest -Uri $machineUri -Token $armToken
$machineId  = $machine.id
$machineMiOid = $machine.identity.principalId
Write-Host "  Arc machine ID     : $machineId"
Write-Host "  Arc machine MI OID : $machineMiOid"

# Look up AA resource group
$aaListUri = "https://management.azure.com/subscriptions/$sub/providers/Microsoft.Automation/automationAccounts?api-version=2023-11-01"
$aaList    = Invoke-ArmRequest -Uri $aaListUri -Token $armToken
$aaRes     = $aaList.value | Where-Object { $_.name -eq $aaName }
if (-not $aaRes) { throw "Automation Account '$aaName' not found in subscription $sub" }
$aaRg      = ($aaRes.id -split '/resourceGroups/')[1].Split('/')[0]

$workerId   = [guid]::NewGuid().ToString()
$workerUri  = "https://management.azure.com/subscriptions/$sub/resourceGroups/$aaRg" +
              "/providers/Microsoft.Automation/automationAccounts/$aaName" +
              "/hybridRunbookWorkerGroups/$hwGroup/hybridRunbookWorkers/$workerId`?api-version=2022-08-08"
$workerBody = @{ properties = @{ vmResourceId = $machineId } } | ConvertTo-Json -Depth 5

Write-Host "  Registering worker (ID: $workerId)..." -NoNewline
try {
    Invoke-ArmRequest -Uri $workerUri -Method PUT -Token $armToken -Body $workerBody | Out-Null
    Write-Host " OK" -ForegroundColor Green
} catch {
    if ($_.Exception.Message -match "409|Conflict|already") {
        Write-Host " Already registered" -ForegroundColor Yellow
    } else { throw }
}

# ===========================================================================
# STEP 5: Grant machine MI "Key Vault Secrets User" on Key Vault
# This allows runbooks on THIS machine to fetch SA tokens and API server IPs
# ===========================================================================
Write-Host ""
Write-Host "[5/6] Granting machine MI 'Key Vault Secrets User' on Key Vault..." -ForegroundColor Yellow

if (-not $machineMiOid) {
    Write-Host "  WARNING: Machine MI OID not found. Run this after Arc connection settles (30 sec) and re-run." -ForegroundColor Red
} else {
    $raUri  = "https://management.azure.com$kvId/providers/Microsoft.Authorization/roleAssignments/" +
              "$([guid]::NewGuid())`?api-version=2022-04-01"
    # Key Vault Secrets User role definition ID (built-in, consistent across all tenants)
    $kvSecretsUserRoleId = "4633458b-17de-408a-b874-0445c86b69e6"
    $raBody = @{
        properties = @{
            roleDefinitionId = "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/$kvSecretsUserRoleId"
            principalId      = $machineMiOid
            principalType    = "ServicePrincipal"
        }
    } | ConvertTo-Json -Depth 5

    try {
        Invoke-ArmRequest -Uri $raUri -Method PUT -Token $armToken -Body $raBody | Out-Null
        Write-Host "  Granted Key Vault Secrets User to machine MI $machineMiOid" -ForegroundColor Green
    } catch {
        if ($_.Exception.Message -match "409|Conflict|already exists|RoleAssignmentExists") {
            Write-Host "  Role already assigned" -ForegroundColor Yellow
        } else {
            Write-Host "  WARNING: Role assignment failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  Manually grant 'Key Vault Secrets User' on $kvId to OID $machineMiOid" -ForegroundColor Yellow
        }
    }
}

# ===========================================================================
# STEP 6: Install HybridWorkerForWindows extension
# ===========================================================================
Write-Host ""
Write-Host "[6/6] Installing HybridWorkerForWindows extension..." -ForegroundColor Yellow
Write-Host "  NOTE: This takes 2-5 minutes. Please wait..." -ForegroundColor DarkYellow

$extUri  = "https://management.azure.com/subscriptions/$sub/resourceGroups/$workerRg" +
           "/providers/Microsoft.HybridCompute/machines/$MachineName" +
           "/extensions/HybridWorkerExtension?api-version=2022-11-10"

$extBody = @{
    location   = $workerLoc
    properties = @{
        publisher               = "Microsoft.Azure.Automation.HybridWorker"
        type                    = "HybridWorkerForWindows"
        typeHandlerVersion      = "1.1"
        autoUpgradeMinorVersion = $true
        settings                = @{
            AutomationAccountURL = $aaUrl
        }
    }
} | ConvertTo-Json -Depth 8

try {
    Invoke-ArmRequest -Uri $extUri -Method PUT -Token $armToken -Body $extBody | Out-Null
    Write-Host "  Extension install submitted" -ForegroundColor Green
} catch {
    if ($_.Exception.Message -match "409|Conflict|already exists") {
        Write-Host "  Already installed - re-applying..." -ForegroundColor Yellow
        Invoke-ArmRequest -Uri $extUri -Method PUT -Token $armToken -Body $extBody | Out-Null
    } else { throw }
}

# Poll until done
Write-Host "  Waiting for extension provisioning (up to 10 min)..."
$deadline  = (Get-Date).AddMinutes(10)
$lastState = ""
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 15
    try {
        $extStatus = Invoke-ArmRequest -Uri $extUri -Token $armToken
        $provState = $extStatus.properties.provisioningState
        if ($provState -ne $lastState) {
            Write-Host "    State: $provState"
            $lastState = $provState
        }
        if ($provState -eq "Succeeded") { break }
        if ($provState -in @("Failed","Canceled")) {
            $msg = $extStatus.properties.instanceView.statuses |
                   Where-Object { $_.level -eq "Error" } |
                   Select-Object -ExpandProperty message -First 1
            throw "Extension $provState. $msg"
        }
    } catch {
        if ($_.Exception.Message -match "Succeeded|Failed|Canceled|provisioning") { throw }
        Write-Host "    (polling...)"
    }
}

# ===========================================================================
# BONUS: Install PowerShell 7 (MSI) + Az modules for PS7 runtime
# Required so runbooks can use PS7 runtime on this hybrid worker.
# MUST use MSI installer (not winget/MSIX) - service needs pwsh.exe in ProgramFiles.
# ===========================================================================
Write-Host ""
Write-Host "[BONUS] Installing PowerShell 7 (MSI) and Az modules..." -ForegroundColor Yellow
Write-Host "  (Required for PS7 runbook runtime on this Hybrid Worker)" -ForegroundColor DarkGray

$pwshExe = "$env:ProgramFiles\PowerShell\7\pwsh.exe"

if (Test-Path $pwshExe) {
    $ver = & $pwshExe --version 2>&1
    Write-Host "  PS7 already installed: $ver" -ForegroundColor Green
} else {
    Write-Host "  Downloading PS7 MSI (NOT winget -- avoids MSIX path issue)..."
    $relJson  = Invoke-ArmRequest -Uri "https://api.github.com/repos/PowerShell/PowerShell/releases/latest" -Token ""
    $msiAsset = $relJson.assets | Where-Object { $_.name -match 'win-x64\.msi$' } | Select-Object -First 1
    if (-not $msiAsset) { throw "Could not find PS7 win-x64.msi in GitHub releases" }
    $msiPath = "$env:TEMP\PowerShell7.msi"
    Write-Host "  Downloading $($msiAsset.name) (~100MB)..." -NoNewline
    Invoke-WebRequest -Uri $msiAsset.browser_download_url -OutFile $msiPath -UseBasicParsing
    Write-Host " Done"
    Write-Host "  Installing (silent, takes ~1 min)..." -NoNewline
    $r = Start-Process msiexec.exe -Wait -PassThru -ArgumentList "/i `"$msiPath`" /quiet /norestart ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ENABLE_PSREMOTING=0"
    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
    if ($r.ExitCode -ne 0) { throw "PS7 MSI failed (exit $($r.ExitCode))" }
    Write-Host " Done" -ForegroundColor Green
}

# Ensure PS7 is in Machine PATH (so the HybridWorker service can find pwsh.exe)
$pwshDir     = Split-Path $pwshExe -Parent
$machinePath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
if (-not ($machinePath -split ";" | Where-Object { $_.TrimEnd("\") -eq $pwshDir.TrimEnd("\") })) {
    [System.Environment]::SetEnvironmentVariable("PATH", $machinePath.TrimEnd(";") + ";" + $pwshDir, "Machine")
    Write-Host "  Added $pwshDir to Machine PATH" -ForegroundColor Green
}

# Install Az modules for PS7 in AllUsers scope (visible to HybridWorker running as SYSTEM)
Write-Host "  Installing Az.Accounts + Az.Resources for PS7 (AllUsers, 3-5 min)..."
foreach ($mod in @("Az.Accounts","Az.Resources")) {
    Write-Host "    $mod..." -NoNewline
    $script = @"
if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue | Where-Object { `$_.Version -ge '2.8.5.201' })) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
}
if (Get-Module -ListAvailable -Name '$mod' -ErrorAction SilentlyContinue) { 'skip' } else {
    Install-Module '$mod' -Force -AllowClobber -Scope AllUsers -Repository PSGallery -SkipPublisherCheck
    'installed'
}
"@
    $out = & $pwshExe -NoProfile -NonInteractive -Command $script 2>&1
    if ($out -match "skip") { Write-Host " Already installed" -ForegroundColor Green }
    elseif ($LASTEXITCODE -eq 0) { Write-Host " OK" -ForegroundColor Green }
    else { Write-Host " FAILED: $out" -ForegroundColor Red }
}

# -- Summary ------------------------------------------------------------------
Write-Host ""
Write-Host "================================================" -ForegroundColor Green
Write-Host "  Registration Complete"                          -ForegroundColor Green
Write-Host "================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Machine '$MachineName' is now a Hybrid Worker."
Write-Host "  Arc MI OID: $machineMiOid"
Write-Host ""
Write-Host "  VERIFY (wait 2-3 min for Online status):" -ForegroundColor Yellow
Write-Host "    Azure Portal -> Automation Accounts -> $aaName"
Write-Host "    -> Hybrid worker groups -> $hwGroup -> Hybrid workers"
Write-Host "    -> '$MachineName' should show as Online"
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
Write-Host "  1. From HCI host: run scripts\Bootstrap-ServiceAccount.ps1"
Write-Host "     to apply SA YAML and store token+IP in Key Vault"
Write-Host "  2. From this machine: run scripts\Test-SATokenAccess.ps1"
Write-Host "     to verify the full auth chain (KV -> SA token -> K8s API)"
Write-Host "  3. Import runbooks from SA-Token-Pattern\runbooks\ into $aaName"
Write-Host ""
Write-Host "  ADD MORE WORKERS:" -ForegroundColor Yellow
Write-Host "    Copy hybrid-worker-state.json + this script to each additional"
Write-Host "    on-prem machine and re-run. Jobs auto-distribute across all workers."
