# Coding Standards — AKS Arc Fleet Pod Restart

This document defines the standards for all scripts, runbooks, Bicep, and YAML in this repository.
Follow these standards in all new code and when modifying existing files.

---

## Table of Contents

1. [PowerShell General](#1-powershell-general)
2. [Parameter Blocks](#2-parameter-blocks)
3. [Error Handling](#3-error-handling)
4. [Logging and Output](#4-logging-and-output)
5. [HTTP and REST Calls](#5-http-and-rest-calls)
6. [Runbook Constraints](#6-runbook-constraints)
7. [Shared-Functions Usage](#7-shared-functions-usage)
8. [Bicep Conventions](#8-bicep-conventions)
9. [Kubernetes YAML Conventions](#9-kubernetes-yaml-conventions)
10. [Naming Conventions](#10-naming-conventions)
11. [State Files and Secrets](#11-state-files-and-secrets)
12. [Testing and Validation](#12-testing-and-validation)

---

## 1. PowerShell General

### File header (all `.ps1` files)

```powershell
#Requires -Version 5.1          # or 7.2 for Hybrid Worker runbooks that need ForEach-Object -Parallel

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12  # every file making HTTPS calls
```

- `Set-StrictMode` catches uninitialized variables and bad property access early.
- `$ErrorActionPreference = "Stop"` ensures non-terminating errors become terminating in scripts.
  - **Exception**: `Shard-RestartPods.ps1` uses `"Continue"` so one cluster failure doesn't abort the whole shard.
- TLS 1.2 must be forced explicitly — Windows Server PS5.1 defaults to TLS 1.0.

### Naming

| Symbol | Convention | Example |
|---|---|---|
| Functions | `Verb-Noun` (approved PS verbs) | `Get-HimdsToken`, `Write-AuditLog` |
| Parameters | `PascalCase` | `$ClusterName`, `$KeyVaultName` |
| Local variables | `camelCase` | `$kvToken`, `$safeCluster` |
| Script-scope helpers | Prefix `$_` | `$_sf`, `$_scriptDir` |
| Constants / config | `PascalCase` | `$SaTokenPrefix` |

Run `Get-Verb` for the full list of approved PowerShell verbs. Do not invent unapproved verbs.

### Collections

```powershell
# Preferred — no array reallocations
$list = [System.Collections.Generic.List[PSCustomObject]]::new()
$list.Add($item)

# Parallel result accumulation — use ConcurrentBag
$bag = [System.Collections.Concurrent.ConcurrentBag[PSCustomObject]]::new()

# Avoid — causes O(n²) reallocation
$arr = @()
$arr += $item
```

### Hashtables

Use `[ordered]@{}` for any hashtable where insertion order matters (audit records, output objects):

```powershell
$auditRecord = [ordered]@{
    TimeGenerated = $startTime.ToString("o")
    ClusterName   = $ClusterName
    Status        = "Started"
}
```

---

## 2. Parameter Blocks

Every script and runbook must declare a `param()` block at the top.

```powershell
param(
    [Parameter(Mandatory)][string]$ClusterName,          # always type-annotate
    [Parameter(Mandatory)][string]$KeyVaultName,
    [string]$Namespace       = "default",                 # defaults have = assignment inline
    [int]   $ThrottleLimit   = 50,
    [switch]$WhatIf                                       # destructive scripts expose -WhatIf
)
```

Rules:
- Every parameter must have an explicit type annotation.
- Mandatory parameters use `[Parameter(Mandatory)]` (not `[Parameter(Mandatory=$true)]`).
- Optional parameters with defaults must have the default on the same line.
- Scripts performing destructive or state-changing operations must support `-WhatIf`.
- `switch` parameters do not need a default (they are `$false` by default).

---

## 3. Error Handling

### Scripts (Bootstrap, Rotate, Deploy, Cleanup)

Use `$ErrorActionPreference = "Stop"` and let errors propagate. Log the error before re-throwing only if you need to add context:

```powershell
try {
    & $kube apply -f $saYaml --kubeconfig $c.Kubeconfig 2>&1
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply failed (exit $LASTEXITCODE)" }
} catch {
    Write-Host "[$($c.Name)] FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
```

### Worker runbook (`Worker-RestartSingleCluster.ps1`)

Use the `Finish` helper pattern so an audit record is always written regardless of outcome, then re-throw:

```powershell
function Finish {
    param([string]$Status, [int]$Http = 0, [string]$Err = "")
    $auditRecord.Status      = $Status
    $auditRecord.HttpStatus  = $Http
    $auditRecord.DurationMs  = [Math]::Round((New-TimeSpan $startTime (Get-Date)).TotalMilliseconds)
    $auditRecord.ErrorDetail = $Err
    if ($wsId -and $wsKey) {
        Write-AuditLog -WorkspaceId $wsId -WorkspaceKey $wsKey -Record $auditRecord
    }
    $col = if ($Status -eq "Success"){'Green'} elseif ($Status -eq "Skipped"){'Yellow'} else {'Red'}
    Write-Host "[$ClusterName] $Status  ${WorkloadType}/$WorkloadName  $($auditRecord.DurationMs)ms" -ForegroundColor $col
}

try {
    # ... main logic ...
    Finish -Status "Success" -Http $patchResp.StatusCode
} catch {
    Finish -Status "Failed" -Err $_.Exception.Message
    throw   # re-throw so Shard tracks failure count
}
```

### Shard runbook (`Shard-RestartPods.ps1`)

Set `$ErrorActionPreference = "Continue"`. Collect results in a `ConcurrentBag`. Never let a single
cluster failure abort the `ForEach-Object -Parallel` block.

---

## 4. Logging and Output

### Write-Host color convention

| Color | Meaning |
|---|---|
| `Cyan` | Section header / major step start |
| `Yellow` | In-progress / warning / WhatIf |
| `Green` | Success |
| `Red` | Error / failure |
| `DarkGray` | Verbose detail / supplementary info |
| `White` | Neutral informational text |

### Section headers

```powershell
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  SA Token Pattern - Infrastructure Deploy" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
```

### Step markers in multi-step scripts

```powershell
Write-Host ""
Write-Host "[1/4] Bicep deployment" -ForegroundColor Cyan
```

### Verbosity

- Use `Write-Host` for user-visible progress (terminal output).
- Use `Write-Verbose` for debug-level detail (controlled by `-Verbose` flag).
- Use `Write-Warning` for non-fatal issues that continue execution.
- Do not use `Write-Output` for progress messages — reserve it for returning structured data from functions.

---

## 5. HTTP and REST Calls

### TLS

Always set before any HTTPS call:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
```

### HttpWebRequest (PS5.1 / cloud runbook)

Use `System.Net.HttpWebRequest` when `HttpClient` is not available or when in the PS5.1 cloud sandbox:

```powershell
$req = [System.Net.HttpWebRequest]::Create($uri)
$req.Method = "GET"
$req.Headers.Add("Authorization", "Bearer $token")
$req.ContentLength = 0
$resp = $req.GetResponse()
$body = [System.IO.StreamReader]::new($resp.GetResponseStream()).ReadToEnd()
$resp.Close()
```

### HttpClient (PS7.2 / Hybrid Worker)

Use `System.Net.Http.HttpClient` for K8s REST calls (supports TLS bypass for self-signed certs):

```powershell
$h = [System.Net.Http.HttpClientHandler]::new()
$h.ServerCertificateCustomValidationCallback = `
    [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
$c = [System.Net.Http.HttpClient]::new($h)
```

> The TLS bypass is intentional — AKS Arc clusters on Azure Local use self-signed certificates
> issued by the cluster CA, not a public CA. See [SECURITY.md](SECURITY.md) for full rationale.

### Return shape for K8s responses

Always use the standard `Invoke-K8sRest` function from `Shared-Functions.ps1`. It returns:

```powershell
[PSCustomObject]@{
    StatusCode = [int]$resp.StatusCode
    Body       = $rbody           # raw JSON string
    Ok         = $resp.IsSuccessStatusCode
}
```

Check `$resp.Ok` before parsing `$resp.Body`.

---

## 6. Runbook Constraints

### Cloud sandbox (`Master-FleetRestart.ps1`)

- **NO** `Import-Module` or `#Requires -Modules` — no external modules in the cloud sandbox.
- Use only built-in AA cmdlets: `Get-AutomationVariable`, `Start-AutomationRunbook`, `Get-AutomationJob`.
- Use `System.Net.HttpWebRequest` for ARM REST calls.
- MSI token endpoint: use `$env:IDENTITY_ENDPOINT` + `$env:IDENTITY_HEADER` (not IMDS 169.254.169.254).

### Hybrid Worker runbooks (`Shard-RestartPods.ps1`, `Worker-RestartSingleCluster.ps1`)

- Can use `ForEach-Object -Parallel` (requires PS7.2).
- Must dot-source `Shared-Functions.ps1` using the defensive path resolution pattern.
- Cannot call `Get-AutomationVariable` — AA variables must be passed as explicit parameters from the Shard.
- Deployed to `C:\Scripts\` on the Hybrid Worker alongside the YAML manifest.

### Passing data between Master → Shard

Use plain semicolon/pipe-delimited text, **not** JSON. AA CliXml-wraps string parameters in a way
that breaks `ConvertFrom-Json` on the Hybrid Worker side:

```powershell
# Master encodes
$clusterData = (@($shard) | ForEach-Object {
    "$($_.name)|$($_.resourceGroup)|$($_.subscriptionId)"
}) -join ";"

# Shard decodes
$clusters = @($ClustersData -split ';' | Where-Object { $_.Trim() } | ForEach-Object {
    $parts = $_ -split '\|'
    [PSCustomObject]@{ name=$parts[0]; resourceGroup=$parts[1]; subscriptionId=$parts[2] }
})
```

---

## 7. Shared-Functions Usage

Dot-source with defensive path resolution at the top of any script that needs it:

```powershell
$_sf = Join-Path $PSScriptRoot "Shared-Functions.ps1"
if (-not (Test-Path $_sf)) { $_sf = "C:\Scripts\Shared-Functions.ps1" }
. $_sf
```

For `scripts/` folder scripts that reference `runbooks/Shared-Functions.ps1`:

```powershell
$_sf = Join-Path $PSScriptRoot "..\runbooks\Shared-Functions.ps1"
if (-not (Test-Path $_sf)) { $_sf = Join-Path $PSScriptRoot "Shared-Functions.ps1" }
if (-not (Test-Path $_sf)) { $_sf = "C:\Scripts\Shared-Functions.ps1" }
. $_sf
```

Do not duplicate the functions in `Shared-Functions.ps1` in other files. Add new shared helpers
to `Shared-Functions.ps1` only — keeping it compatible with both PS5.1 and PS7.2.

---

## 8. Bicep Conventions

### File structure

```bicep
// main.bicep
// <Project name> - <Purpose>
// Deploys: <comma-separated resource list>
// Called by: <script name>

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------
@description('...')
param location string

// ---------------------------------------------------------------------------
// <Resource Group Name>
// ---------------------------------------------------------------------------
resource <camelCaseName> '<type>@<api-version>' = {
  ...
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output <camelCaseName> <type> = <resource>.<property>
```

### Rules

- Every `param` must have an `@description('...')` decorator.
- Every resource referenced by the PS1 wrapper post-deploy must appear in `output`.
- Role assignment names must use deterministic `guid()`:
  ```bicep
  name: guid(keyVault.id, automationAccountName, roleDefinitionId)
  ```
- Subscription-scoped role assignments go in the PS1 wrapper (not Bicep) — subscription-scoped
  Bicep targets require a different deployment command.
- Use latest stable API versions. Check current versions at `aka.ms/bicep-types`.

---

## 9. Kubernetes YAML Conventions

All K8s objects created by this project must carry these labels:

```yaml
labels:
  app: azure-automation-restart
  managed-by: arc-automation
```

| Object | Name | Namespace |
|---|---|---|
| ServiceAccount | `automation-restart` | `kube-system` |
| Secret (SA token) | `automation-restart-token` | `kube-system` |
| ClusterRole | `automation-restart-role` | cluster-scoped |
| ClusterRoleBinding | `automation-restart-binding` | cluster-scoped |

The ClusterRole must be **least-privilege**:

```yaml
rules:
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets", "daemonsets"]
  verbs: ["get", "list", "patch"]
- apiGroups: [""]
  resources: ["namespaces", "pods"]
  verbs: ["get", "list"]
```

Do not add `delete`, `create`, `update`, or `watch` unless there is a documented requirement.

---

## 10. Naming Conventions

### Azure resources

| Resource | Pattern | Example |
|---|---|---|
| Automation Account | `aa-<project>-<env>` | `aa-aksarc-restart` |
| Key Vault | `kv-<project>-<env>` | `kv-aksarc-automation` |
| Log Analytics Workspace | `law-<project>-<env>` | `law-aksarc-restart` |
| Resource Group | `rg-<project>-<env>` | `rg-aksarc-automation` |
| Logic App | `logic-<project>-<purpose>` | `logic-aksarc-restart-trigger` |
| Hybrid Worker Group | `<PascalCase>Workers` | `AKSArcWorkers` |

### Key Vault secrets

| Secret | Value | Naming |
|---|---|---|
| SA JWT token | K8s service account JWT | `satoken-<sanitized-cluster-name>` |
| API server address | `<ip>:<port>` | `apiserver-<sanitized-cluster-name>` |

Cluster name sanitization function: `$name -replace '[^a-zA-Z0-9-]','-'`

Prefixes are configurable via `AA-SaTokenPrefix` and `AA-ApiServerPrefix` AA variables.

### Automation Account variables

All variables prefixed `AA-`. Do not use this prefix for any other purpose.

---

## 11. State Files and Secrets

**State JSON files are deployment artifacts — never commit them.**

| File | Generated by | Purpose |
|---|---|---|
| `infra/infra-state.json` | `Deploy-Infrastructure.ps1` | Stores subscription, RG, MI OID, KV ID, workspace ID |
| `infra/hybrid-worker-state.json` | `Setup-HybridWorkerGroup.ps1` | Stores worker group details |
| `infra/logic-app-state.json` | `Deploy-LogicApp.ps1` | Stores Logic App trigger URL (SAS-signed) |

All three are gitignored. Use the `*.example.json` stubs in `infra/` to communicate schema to new
contributors.

The Logic App trigger URL is a **secret** (it contains a SAS signature). Treat it like a password:
- Store it in Key Vault after initial deploy.
- Do not embed it in scripts or pipeline variables in plaintext.
- Rotate by re-running `Deploy-LogicApp.ps1` (generates a new trigger URL).

---

## 12. Testing and Validation

### After bootstrap

```powershell
.\scripts\Test-SATokenAccess.ps1 `
    -KeyVaultName "kv-aksarc-automation" `
    -ClusterName  "cluster-name"
```

Verifies: himds token → KV token → SA token → API server → TCP → K8s REST GET.

### Before any destructive operation

All `infra/` and `scripts/` scripts support `-WhatIf`. Always run with `-WhatIf` first:

```powershell
.\infra\Deploy-Infrastructure.ps1 ... -WhatIf
.\scripts\Cleanup-AzureResources.ps1 ... -WhatIf
```

### Runbook smoke test

Use `coredns` in `kube-system` — it self-heals and is safe to restart:

```
Namespace    = "kube-system"
WorkloadType = "deployment"
WorkloadName = "coredns"
```

### PSScriptAnalyzer

Run the linter before committing runbook or script changes:

```powershell
Invoke-ScriptAnalyzer -Path .\runbooks\ -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\scripts\ -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path .\infra\    -Settings .\PSScriptAnalyzerSettings.psd1
```
