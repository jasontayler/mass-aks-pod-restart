#Requires -Version 5.1
# Bootstrap-ServiceAccount.ps1
# PURPOSE : One-time setup per cluster. Creates the K8s service account and
#           stores its token + API server address in Azure Key Vault.
# RUN ON  : AzureStackHCI host OR any jump box that can reach clusters on LAN
#           AND has Owner/Contributor on the Key Vault.
# PREREQS : kubectl in PATH (or C:\tools\kubectl.exe)
#           Az.Accounts module (for Connect-AzAccount if not using himds)
#           Admin kubeconfig for each cluster
#
# USAGE:
#   # Single cluster — single-context kubeconfig (auto-detects context)
#   .\Bootstrap-ServiceAccount.ps1 `
#     -KeyVaultName "aks-sa-accounts" `
#     -ClusterName  "az-nuc01-aks02" `
#     -KubeconfigPath "C:\Users\Jason\.kube\config" `
#     -ContextName    "az-nuc01-aks02-31d036df-admin@az-nuc01-aks02-31d036df"
#
#   # Merged kubeconfig (MUST supply -ContextName to avoid wrong cluster)
#   .\Bootstrap-ServiceAccount.ps1 `
#     -KeyVaultName   "aks-sa-accounts" `
#     -ClusterName    "azl-nuc2-aks01" `
#     -KubeconfigPath "$env:USERPROFILE\.kube\config" `
#     -ContextName    "azl-nuc2-aks01-9d9b5de8-admin@azl-nuc2-aks01-9d9b5de8"
#
#   # To list available context names in the merged kubeconfig:
#   kubectl config get-contexts -o name
#
#   # All clusters on this HCI host (auto-discovers via Get-AksHciCluster)
#   .\Bootstrap-ServiceAccount.ps1 `
#     -KeyVaultName "aks-sa-accounts" `
#     -AutoDiscover

param(
    [Parameter(Mandatory)][string]$KeyVaultName,
    [string]$ClusterName      = "",
    [string]$KubeconfigPath   = "",        # path to admin kubeconfig (merged or single)
    [string]$ContextName      = "",        # REQUIRED when kubeconfig is merged: kubectl context name
                                           # e.g. "az-nuc01-aks02-31d036df-admin@az-nuc01-aks02-31d036df"
    [switch]$AutoDiscover,                 # use Get-AksHciCluster on HCI host
    [string]$ApiServerOverride = "",       # "10.x.x.x:6443" -- skip ARM discovery
    [string]$SaYamlPath        = "",       # defaults to .\k8s\restart-sa.yaml
    [string]$SecretPrefix      = "satoken",
    [string]$ApiServerPrefix   = "apiserver",
    [int]   $ParallelJobs      = 5,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Bug 5 fix: check multiple candidate paths so the script works whether it's
# deployed directly in C:\Scripts or in a scripts\ subdirectory.
$saYaml = if ($SaYamlPath) {
    $SaYamlPath
} else {
    @(
        (Join-Path $PSScriptRoot "k8s\restart-sa.yaml"),          # C:\Scripts\k8s\restart-sa.yaml
        (Join-Path $PSScriptRoot "..\k8s\restart-sa.yaml"),       # C:\<root>\k8s\restart-sa.yaml
        "C:\Scripts\k8s\restart-sa.yaml"                          # hard fallback
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $saYaml) { throw "SA YAML not found. Specify -SaYamlPath, or place restart-sa.yaml in C:\Scripts\k8s\" }

# Find kubectl
$kube = Get-Command kubectl -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $kube) {
    foreach ($c in @("C:\tools\kubectl.exe","C:\kubectl\kubectl.exe")) {
        if (Test-Path $c) { $kube = $c; break }
    }
}
if (-not $kube) { throw "kubectl not found. Install to C:\tools\kubectl.exe" }
Write-Host "kubectl: $kube" -ForegroundColor Green

# Get ARM token (himds if on worker, Connect-AzAccount if on admin machine)
$armToken = $null
try {
    . (Join-Path $PSScriptRoot "Shared-Functions.ps1")
    $armToken = Get-HimdsToken -Resource "https://management.azure.com/"
    Write-Host "ARM token via himds OK" -ForegroundColor Green
} catch {
    Write-Host "himds not available -- trying Connect-AzAccount" -ForegroundColor Yellow
    foreach ($mod in @('Az.Accounts','Az.KeyVault')) {
        if (-not (Get-Module $mod -ListAvailable)) {
            Install-Module $mod -Force -Scope CurrentUser -Repository PSGallery
        }
    }
    Connect-AzAccount
    $armToken = $null  # not used for KV writes -- Az.KeyVault cmdlets use the context directly
}

# Get KV token — only needed if running on a himds (Hybrid Worker) machine.
# When using Connect-AzAccount, KV writes go via Set-AzKeyVaultSecret (no raw token needed).
$kvToken = $null
try { $kvToken = Get-HimdsToken -Resource "https://vault.azure.net" }
catch { $kvToken = $null }  # will use Az.KeyVault cmdlets instead

# Build cluster list
$clusters = [System.Collections.Generic.List[PSCustomObject]]::new()
if ($AutoDiscover) {
    Write-Host "Auto-discovering clusters via Get-AksHciCluster..." -ForegroundColor Yellow
    $hciClusters = Get-AksHciCluster
    foreach ($c in $hciClusters) {
        $tmpKube = "$env:TEMP\kube-$($c.Name)-admin.yaml"
        Get-AksHciCredential -Name $c.Name -Confirm:$false
        Copy-Item "$env:USERPROFILE\.kube\config" $tmpKube -Force
        Remove-Item "$env:USERPROFILE\.kube\config" -Force -ErrorAction SilentlyContinue
    $clusters.Add([PSCustomObject]@{ Name=$c.Name; Kubeconfig=$tmpKube; Context=""; ApiServer="" })
    }
} elseif ($ClusterName -and $KubeconfigPath) {
    # Accept either a directory (resolves to <dir>\config) or an explicit file
    if ((Get-Item $KubeconfigPath -ErrorAction SilentlyContinue).PSIsContainer) {
        $KubeconfigPath = Join-Path $KubeconfigPath "config"
    }
    if (-not (Test-Path $KubeconfigPath)) { throw "Kubeconfig not found: $KubeconfigPath" }

    # Auto-detect context if not provided: if kubeconfig has exactly one context use it,
    # otherwise require -ContextName to avoid applying to the wrong cluster.
    if (-not $ContextName) {
        $allContexts = & $kube config get-contexts --kubeconfig $KubeconfigPath -o name 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Cannot read contexts from kubeconfig: $allContexts" }
        $ctxList = @($allContexts | Where-Object { $_ -and $_ -notmatch '^error' })
        if ($ctxList.Count -eq 1) {
            $ContextName = $ctxList[0]
            Write-Host "Auto-selected context: $ContextName" -ForegroundColor Yellow
        } elseif ($ctxList.Count -gt 1) {
            throw "Kubeconfig has $($ctxList.Count) contexts. Specify -ContextName to avoid applying to the wrong cluster.`nAvailable: $($ctxList -join ', ')"
        }
    }
    $clusters.Add([PSCustomObject]@{ Name=$ClusterName; Kubeconfig=$KubeconfigPath; Context=$ContextName; ApiServer=$ApiServerOverride })
} else {
    throw "Provide -ClusterName + -KubeconfigPath, or use -AutoDiscover"
}

Write-Host "`nProcessing $($clusters.Count) cluster(s)..." -ForegroundColor Cyan

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($c in $clusters) {

    $result = [PSCustomObject]@{
        Cluster   = $c.Name
        Status    = "Unknown"
        SaToken   = $null
        ApiServer = $null
        Error     = $null
    }

    try {
        Write-Host "[$($c.Name)] Applying SA manifest..." -ForegroundColor Yellow

        # Bug 1 fix: always pass --context so a merged kubeconfig targets the right cluster.
        $ctxArgs = if ($c.Context) { @("--context", $c.Context) } else { @() }

        if (-not $WhatIf) {
            $out = & $kube apply -f $saYaml --kubeconfig $c.Kubeconfig @ctxArgs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "kubectl apply failed: $($out -join ' ')" }
            Write-Host "[$($c.Name)] SA applied OK" -ForegroundColor Green

            # Bug 4 fix: verify the SA actually landed on THIS cluster before continuing.
            $verifySa = & $kube get sa automation-restart -n kube-system `
                --kubeconfig $c.Kubeconfig @ctxArgs `
                -o jsonpath="{.metadata.name}" 2>&1
            if ($LASTEXITCODE -ne 0 -or $verifySa -ne "automation-restart") {
                throw "SA verification failed after apply (context='$($c.Context)'). Got: $verifySa"
            }
            Write-Host "[$($c.Name)] SA verified on cluster" -ForegroundColor Green

            # Wait for token to be populated in Secret
            $token = $null
            for ($i = 0; $i -lt 15; $i++) {
                Start-Sleep -Seconds 2
                $secretJson = & $kube get secret automation-restart-token -n kube-system `
                    -o json --kubeconfig $c.Kubeconfig @ctxArgs 2>&1 | Out-String
                if ($LASTEXITCODE -eq 0) {
                    $secretObj = $secretJson | ConvertFrom-Json
                    $tokenB64  = $secretObj.data.token
                    if ($tokenB64) {
                        $token = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($tokenB64)).Trim()
                        break
                    }
                }
            }
            if (-not $token) { throw "SA token not generated after 30s" }
            Write-Host "[$($c.Name)] SA token extracted ($($token.Length) chars)" -ForegroundColor Green
            $result.SaToken = $token

            # Discover API server from the context specified (Bug 1 + Bug 2 fix).
            $apiServer = $c.ApiServer
            if (-not $apiServer) {
                $useCtx     = if ($c.Context) { $c.Context } else {
                    & $kube config current-context --kubeconfig $c.Kubeconfig 2>&1
                }
                $clusterRef = & $kube config view --kubeconfig $c.Kubeconfig `
                    -o "jsonpath={.contexts[?(@.name=='$useCtx')].context.cluster}" 2>&1
                $apiServer  = & $kube config view --kubeconfig $c.Kubeconfig `
                    -o "jsonpath={.clusters[?(@.name=='$clusterRef')].cluster.server}" 2>&1
                $apiServer  = "$apiServer".Trim() -replace '^https?://',''
                # Bug 2 fix: ensure port is present — AKS Arc API server is always 6443.
                if ($apiServer -and $apiServer -notmatch ':\d+$') {
                    $apiServer = "${apiServer}:6443"
                    Write-Host "[$($c.Name)] No port in kubeconfig server — defaulted to :6443" -ForegroundColor Yellow
                }
            }
            if (-not $apiServer) { throw "Could not determine API server address" }
            Write-Host "[$($c.Name)] API server: $apiServer" -ForegroundColor Green
            $result.ApiServer = $apiServer

            # Build KV secret names
            $saSecretName  = "$SecretPrefix-$($c.Name -replace '[^a-zA-Z0-9-]','-')"
            $apiSecretName = "$ApiServerPrefix-$($c.Name -replace '[^a-zA-Z0-9-]','-')"

            # Bug 3 fix: try REST (himds), fall back to az CLI (proven to work), then Az module.
            $kvWritten = $false
            if ($kvToken) {
                try {
                    $kvBase  = "https://$KeyVaultName.vault.azure.net/secrets"
                    $headers = @{ Authorization="Bearer $kvToken"; "Content-Type"="application/json" }
                    Invoke-RestMethod -Uri "$kvBase/$saSecretName`?api-version=7.4" -Method PUT `
                        -Headers $headers `
                        -Body (@{
                            value      = $token
                            attributes = @{ enabled=$true }
                            tags       = @{ cluster=$c.Name; type="sa-token"; updated=(Get-Date -Format 'yyyy-MM-dd') }
                        } | ConvertTo-Json) | Out-Null
                    Invoke-RestMethod -Uri "$kvBase/$apiSecretName`?api-version=7.4" -Method PUT `
                        -Headers $headers `
                        -Body (@{
                            value      = $apiServer
                            attributes = @{ enabled=$true }
                            tags       = @{ cluster=$c.Name; type="api-server"; updated=(Get-Date -Format 'yyyy-MM-dd') }
                        } | ConvertTo-Json) | Out-Null
                    $kvWritten = $true
                    Write-Host "[$($c.Name)] KV written via himds REST" -ForegroundColor Green
                } catch {
                    Write-Host "[$($c.Name)] himds REST to KV failed ($($_.Exception.Message)) — falling back to az CLI" -ForegroundColor Yellow
                }
            }

            if (-not $kvWritten) {
                # az CLI fallback — works as long as 'az login' was done on this machine.
                $azCheck = Get-Command az -ErrorAction SilentlyContinue
                if ($azCheck) {
                    $r1 = az keyvault secret set --vault-name $KeyVaultName --name $saSecretName  --value $token     2>&1
                    if ($LASTEXITCODE -ne 0) { throw "az keyvault secret set failed for $saSecretName`: $r1" }
                    $r2 = az keyvault secret set --vault-name $KeyVaultName --name $apiSecretName --value $apiServer  2>&1
                    if ($LASTEXITCODE -ne 0) { throw "az keyvault secret set failed for $apiSecretName`: $r2" }
                    $kvWritten = $true
                    Write-Host "[$($c.Name)] KV written via az CLI" -ForegroundColor Green
                }
            }

            if (-not $kvWritten) {
                # Last resort: Az.KeyVault module (requires Connect-AzAccount session).
                $tags = @{ cluster=$c.Name; updated=(Get-Date -Format 'yyyy-MM-dd') }
                Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $saSecretName `
                    -SecretValue (ConvertTo-SecureString $token -AsPlainText -Force) `
                    -Tag ($tags + @{ type="sa-token" }) | Out-Null
                Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $apiSecretName `
                    -SecretValue (ConvertTo-SecureString $apiServer -AsPlainText -Force) `
                    -Tag ($tags + @{ type="api-server" }) | Out-Null
                $kvWritten = $true
                Write-Host "[$($c.Name)] KV written via Az.KeyVault module" -ForegroundColor Green
            }

            Write-Host "[$($c.Name)] KV secrets '$saSecretName' + '$apiSecretName' written" -ForegroundColor Green
            $result.Status = "Success"
        } else {
            Write-Host "[$($c.Name)] WHATIF -- would apply SA and write KV secrets" -ForegroundColor DarkYellow
            $result.Status = "WhatIf"
        }
    } catch {
        $result.Status = "Failed"
        $result.Error  = $_.Exception.Message
        Write-Host "[$($c.Name)] FAILED: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        # Clean up temp kubeconfig if auto-discovered
        if ($c.Kubeconfig -match 'kube-.*-admin\.yaml$') {
            Remove-Item $c.Kubeconfig -Force -ErrorAction SilentlyContinue
        }
        $results.Add($result)
    }
}

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host "  BOOTSTRAP SUMMARY" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
$results | Sort-Object Cluster | Format-Table Cluster, Status, ApiServer, Error -AutoSize

$failed = @($results | Where-Object { $_.Status -eq "Failed" })
if ($failed.Count -gt 0) {
    Write-Host "Failed clusters ($($failed.Count)):" -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "  $($_.Cluster): $($_.Error)" -ForegroundColor Red }
    exit 1
} else {
    Write-Host "All $($results.Count) cluster(s) bootstrapped successfully." -ForegroundColor Green
    Write-Host "Next step: run Test-SATokenAccess.ps1 to verify." -ForegroundColor White
}
