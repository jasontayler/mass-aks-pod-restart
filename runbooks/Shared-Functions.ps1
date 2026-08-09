#Requires -Version 5.1
# Shared-Functions.ps1
# Dot-source this at the top of every runbook:
#   . "$PSScriptRoot\Shared-Functions.ps1"
# Contains: Get-HimdsToken, Get-KvSecret, Invoke-K8sRest, Write-AuditLog, Test-TcpPort

# PS5.1 on Windows Server defaults to TLS 1.0 -- force TLS 1.2 globally
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── himds token (Hybrid Identity Metadata Service) ──────────────────────────
# Works for any Azure resource audience. Handles the 401 challenge flow.
function Get-HimdsToken {
    param([string]$Resource = "https://management.azure.com/")
    $url = "http://localhost:40342/metadata/identity/oauth2/token?api-version=2020-06-01&resource=$Resource"
    $wr1 = [System.Net.HttpWebRequest]::Create($url)
    $wr1.Method = "GET"; $wr1.UseDefaultCredentials = $false; $wr1.Credentials = $null
    $wr1.AllowAutoRedirect = $false; $wr1.Timeout = 15000
    $wr1.Headers.Add("Metadata","true")
    try { $rs1 = $wr1.GetResponse() }
    catch [System.Net.WebException] {
        $rs1 = $_.Exception.Response
        if (-not $rs1) { throw "himds unreachable: $($_.Exception.Message)" }
    }
    $sc1 = [int]$rs1.StatusCode
    if ($sc1 -eq 200) {
        $b = [System.IO.StreamReader]::new($rs1.GetResponseStream()).ReadToEnd()
        $rs1.Close()
        return ($b | ConvertFrom-Json).access_token
    }
    if ($sc1 -ne 401) {
        $b = [System.IO.StreamReader]::new($rs1.GetResponseStream()).ReadToEnd()
        $rs1.Close()
        throw "himds HTTP $sc1 : $b"
    }
    $wwwAuth = [string]$rs1.Headers["WWW-Authenticate"]
    $rs1.Close()
    if ($wwwAuth -notmatch 'realm="?([^",\s]+)"?') { throw "himds no realm in: $wwwAuth" }
    $secret = (Get-Content $Matches[1] -Raw).Trim()
    $wr2 = [System.Net.HttpWebRequest]::Create($url)
    $wr2.Method = "GET"; $wr2.UseDefaultCredentials = $false; $wr2.Credentials = $null
    $wr2.AllowAutoRedirect = $false; $wr2.Timeout = 15000
    $wr2.Headers.Add("Metadata","true")
    $wr2.Headers.Add("Authorization","Basic $secret")
    try { $rs2 = $wr2.GetResponse() }
    catch [System.Net.WebException] {
        $rs2 = $_.Exception.Response
        if ($rs2) {
            $b = [System.IO.StreamReader]::new($rs2.GetResponseStream()).ReadToEnd()
            $rs2.Close()
            throw "himds auth HTTP $([int]$rs2.StatusCode): $b"
        }
        throw "himds auth: $($_.Exception.Message)"
    }
    $b2 = [System.IO.StreamReader]::new($rs2.GetResponseStream()).ReadToEnd()
    $rs2.Close()
    return ($b2 | ConvertFrom-Json).access_token
}

# ── Key Vault secret retrieval (no Az module needed) ────────────────────────
function Get-KvSecret {
    param(
        [Parameter(Mandatory)][string]$VaultName,
        [Parameter(Mandatory)][string]$SecretName,
        [string]$KvToken = $null
    )
    if (-not $KvToken) { $KvToken = Get-HimdsToken -Resource "https://vault.azure.net" }
    $uri = "https://$VaultName.vault.azure.net/secrets/$SecretName`?api-version=7.4"
    $wr  = [System.Net.HttpWebRequest]::Create($uri)
    $wr.Method = "GET"
    $wr.Headers.Add("Authorization", "Bearer $KvToken")
    # Force TLS 1.2 on the request itself (ServicePointManager may not apply in all PS5.1 contexts)
    $wr.ServicePoint.ConnectionLimit = 10
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $rs   = $wr.GetResponse()
        $body = [System.IO.StreamReader]::new($rs.GetResponseStream()).ReadToEnd()
        $rs.Close()
    } catch [System.Net.WebException] {
        $rs = $_.Exception.Response
        if ($rs) {
            $body = [System.IO.StreamReader]::new($rs.GetResponseStream()).ReadToEnd()
            $rs.Close()
            throw "KV HTTP $([int]$rs.StatusCode): $body"
        }
        throw "KV request failed: $($_.Exception.Message)"
    }
    return ($body | ConvertFrom-Json).value.Trim()
}

# ── Kubernetes REST call (cert bypass, Bearer token) ────────────────────────
function Invoke-K8sRest {
    param(
        [Parameter(Mandatory)][string]$ApiServer,   # e.g. "10.10.10.26:6443"
        [Parameter(Mandatory)][string]$Path,         # e.g. "/api/v1/namespaces"
        [Parameter(Mandatory)][string]$Token,        # SA JWT
        [string]$Method      = "GET",
        [string]$Body        = $null,
        [string]$ContentType = "application/strategic-merge-patch+json",
        [int]   $TimeoutSec  = 15
    )
    $base = if ($ApiServer -match '^https?://') { $ApiServer } else { "https://$ApiServer" }
    $h = [System.Net.Http.HttpClientHandler]::new()
    $h.ServerCertificateCustomValidationCallback = [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
    $c = [System.Net.Http.HttpClient]::new($h)
    $c.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    $req = [System.Net.Http.HttpRequestMessage]::new(
        [System.Net.Http.HttpMethod]::new($Method),
        [Uri]"$base$Path"
    )
    $req.Headers.TryAddWithoutValidation("Authorization","Bearer $Token") | Out-Null
    if ($Body) {
        $req.Content = [System.Net.Http.StringContent]::new(
            $Body, [System.Text.Encoding]::UTF8, $ContentType
        )
    }
    $resp  = $c.SendAsync($req).GetAwaiter().GetResult()
    $rbody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    return [PSCustomObject]@{
        StatusCode = [int]$resp.StatusCode
        Body       = $rbody
        Ok         = $resp.IsSuccessStatusCode
    }
}

# ── Log Analytics audit writer ───────────────────────────────────────────────
# Uses the Log Analytics Data Collector API (HTTP Data Collector).
# Requires WorkspaceId + WorkspaceKey (stored as Automation variables).
function Write-AuditLog {
    param(
        [Parameter(Mandatory)][string]$WorkspaceId,
        [Parameter(Mandatory)][string]$WorkspaceKey,
        [Parameter(Mandatory)][hashtable]$Record,
        [string]$LogType = "AKSArcRestart"
    )
    $body     = $Record | ConvertTo-Json -Compress
    $bodyBytes= [System.Text.Encoding]::UTF8.GetBytes($body)
    $dateStr  = [DateTime]::UtcNow.ToString("R")
    $strToSign= "POST`n$($bodyBytes.Length)`napplication/json`nx-ms-date:$dateStr`n/api/logs"
    $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
    $hmac     = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
    $sig      = [Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($strToSign)))
    $uri      = "https://$WorkspaceId.ods.opinsights.azure.com/api/logs?api-version=2016-04-01"
    try {
        Invoke-RestMethod -Uri $uri -Method POST -Body $body -ContentType "application/json" `
            -Headers @{
                "Log-Type"    = $LogType
                "x-ms-date"   = $dateStr
                "Authorization" = "SharedKey ${WorkspaceId}:${sig}"
            } -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "AuditLog write failed: $($_.Exception.Message)"
    }
}

# ── TCP port check ───────────────────────────────────────────────────────────
function Test-TcpPort {
    param([string]$Hostname,[int]$Port,[int]$TimeoutMs = 3000)
    try {
        $t  = [System.Net.Sockets.TcpClient]::new()
        $ok = $t.ConnectAsync($Hostname,$Port).Wait($TimeoutMs)
        $t.Close()
        return $ok
    } catch { return $false }
}
