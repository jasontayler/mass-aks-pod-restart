#Requires -Version 5.1
# Test-GraphQuery.ps1
# USAGE: .\Test-GraphQuery.ps1 -SubscriptionId <id> [-ClusterFilter "| where name =~ 'mycluster'"]

param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ClusterFilter = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 1. Get ARM token via HIMDS
Write-Host "Getting ARM token via HIMDS..." -ForegroundColor Cyan
$armToken = $null

if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
    Write-Host "  Using IDENTITY_ENDPOINT (extension-based HW)" -ForegroundColor DarkGray
    $url = "$($env:IDENTITY_ENDPOINT)?resource=$([uri]::EscapeDataString('https://management.azure.com/'))&api-version=2019-08-01"
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = "GET"
    $req.Headers.Add("X-IDENTITY-HEADER", $env:IDENTITY_HEADER)
    $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
} else {
    Write-Host "  Using HIMDS localhost:40342 (agent-based HW)" -ForegroundColor DarkGray
    $url = "http://localhost:40342/metadata/identity/oauth2/token?api-version=2019-11-01&resource=$([uri]::EscapeDataString('https://management.azure.com/'))"
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = "GET"
    $req.Headers.Add("Metadata", "true")
    $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
}
$resp = $req.GetResponse()
$armToken = ([System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd() | ConvertFrom-Json).access_token
$resp.Close()
Write-Host "  Token OK (first 20): $($armToken.Substring(0,20))..." -ForegroundColor Green

# 2. Build query -- same structure as Master-FleetRestart
$graphQuery = @"
Resources
| where type =~ 'microsoft.kubernetes/connectedclusters'
| where properties.connectivityStatus =~ 'Connected'
$ClusterFilter
| project name, resourceGroup, subscriptionId, tags, properties.connectivityStatus, properties.kubernetesVersion
"@

Write-Host "`nKQL sent:" -ForegroundColor Cyan
Write-Host $graphQuery -ForegroundColor DarkGray

# 3. POST to Resource Graph
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(
    (@{ query = $graphQuery; subscriptions = @($SubscriptionId) } | ConvertTo-Json -Depth 5))

$req = [System.Net.HttpWebRequest]::Create(
    "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01")
$req.Method = "POST"; $req.ContentType = "application/json"; $req.ContentLength = $bodyBytes.Length
$req.Headers.Add("Authorization", "Bearer $armToken"); $req.Accept = "application/json"
$proxy = [System.Net.WebRequest]::GetSystemWebProxy()
$proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
$req.Proxy = $proxy
$s = $req.GetRequestStream(); $s.Write($bodyBytes, 0, $bodyBytes.Length); $s.Close()

try {
    $resp = $req.GetResponse()
} catch [System.Net.WebException] {
    $errBody = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream()).ReadToEnd()
    throw "Resource Graph HTTP $([int]$_.Exception.Response.StatusCode): $errBody"
}
$result = [System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd() | ConvertFrom-Json
$resp.Close()

# 4. Print
$rows = @($result.data)
Write-Host "`nResults: $($rows.Count) cluster(s)" -ForegroundColor $(if ($rows.Count) {'Green'} else {'Red'})

if ($rows.Count -eq 0) {
    Write-Host "  Tip: run without -ClusterFilter first to see actual names and tags" -ForegroundColor Yellow
    Write-Host "  Tip: use =~ not == for case-insensitive: | where name =~ 'mycluster'" -ForegroundColor Yellow
    Write-Host "  Tip: tag filter needs actual tag key: | where tags['environment'] =~ 'nonprod'" -ForegroundColor Yellow
} else {
    foreach ($row in $rows) {
        Write-Host "--- Cluster ---" -ForegroundColor Green
        Write-Host "  name          : $($row.name)"
        Write-Host "  resourceGroup : $($row.resourceGroup)"
        Write-Host "  subscriptionId: $($row.subscriptionId)"
        Write-Host "  connectivity  : $($row.'properties.connectivityStatus')"
        Write-Host "  k8s version   : $($row.'properties.kubernetesVersion')"
        Write-Host "  tags          : $(if ($row.tags) { $row.tags | ConvertTo-Json -Compress } else { '(none)' })"
        Write-Host ""
    }
    Write-Host "---- Data string as Master builds it ----" -ForegroundColor Cyan
    $rows | ForEach-Object { Write-Host "  $($_.name)~$($_.resourceGroup)~$($_.subscriptionId)" }
}