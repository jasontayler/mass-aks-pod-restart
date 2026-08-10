# AKS Arc Fleet Pod Restart — Copilot Instructions

## Project purpose

Mass-restart Kubernetes workloads across 800+ AKS Arc (connected) clusters on Azure Local (HCI)
using the **SA Token Pattern**: Kubernetes service account JWT tokens stored per-cluster in
Azure Key Vault, fetched at runtime by Hybrid Workers via himds (no kubeconfig, no kubectl,
no Az modules at restart time).

---

## Architecture

```
BOOTSTRAP (one-time, from HCI host)
  kubectl apply restart-sa.yaml → ServiceAccount + ClusterRole (patch-only on apps/*)
  Extract SA token → write to Key Vault as satoken-<clustername>
  Extract API server → write to Key Vault as apiserver-<clustername>

RUNTIME (per restart job)
  Azure Automation cloud → Master-FleetRestart.ps1
    Resource Graph → enumerate all Connected clusters
    Shard into 50-cluster chunks
    Start-AutomationRunbook Shard-RestartPods.ps1 × N  (parallel, RunOn Hybrid Worker)

  Hybrid Worker (on-prem, same LAN as clusters) → Shard-RestartPods.ps1
    ForEach-Object -Parallel -ThrottleLimit 50
      Worker-RestartSingleCluster.ps1 per cluster:
        himds → KV bearer token
        Key Vault REST → SA JWT + API server address
        PATCH https://<ip>:6443/apis/apps/v1/namespaces/<ns>/<type>/<name>
        Write-AuditLog → Log Analytics (AKSArcRestart_CL)
```

---

## Runbook environment matrix

| Runbook | PS Version | Runs on | Notes |
|---|---|---|---|
| `Master-FleetRestart.ps1` | 5.1 | Cloud sandbox | No external modules; uses `HttpWebRequest` |
| `Shard-RestartPods.ps1` | 7.2 | Hybrid Worker | Uses `ForEach-Object -Parallel` |
| `Worker-RestartSingleCluster.ps1` | 7.2 | Hybrid Worker | Dot-sources `Shared-Functions.ps1` |
| `Shared-Functions.ps1` | 5.1+ | Both | Library; never run directly |

**Critical constraint**: Cloud runbooks (`Master-FleetRestart.ps1`) MUST NOT import external Az
modules. Use `Get-AutomationVariable`, `Start-AutomationRunbook`, `Get-AutomationJob` (all
built-in AA cmdlets) and raw `System.Net.HttpWebRequest` for ARM REST calls.

---

## Shared-Functions.ps1 — canonical patterns

All runtime scripts dot-source this file. Resolve path defensively (works in both repo layout and flat `C:\Scripts\` deployment):

```powershell
$_sf = Join-Path $PSScriptRoot "Shared-Functions.ps1"
if (-not (Test-Path $_sf)) { $_sf = "C:\Scripts\Shared-Functions.ps1" }
. $_sf
```

### Available functions

| Function | Purpose |
|---|---|
| `Get-HimdsToken -Resource <uri>` | Get bearer token from local himds (port 40342). Handles 401-challenge flow. |
| `Get-KvSecret -VaultName -SecretName [-KvToken]` | Fetch a secret value from Key Vault REST API 7.4. |
| `Invoke-K8sRest -ApiServer -Path -Token [-Method] [-Body] [-ContentType] [-TimeoutSec]` | Call K8s API using `HttpClient`. Returns `{StatusCode, Body, Ok}`. |
| `Write-AuditLog -WorkspaceId -WorkspaceKey -Record [-LogType]` | POST audit record to Log Analytics via HTTP Data Collector API. |
| `Test-TcpPort -Hostname -Port [-TimeoutMs]` | Fast TCP probe before K8s REST calls. Returns `$true`/`$false`. |

---

## Key Vault secret naming convention

| Secret name | Content | Set by |
|---|---|---|
| `satoken-<sanitized-cluster-name>` | K8s SA JWT token | `Bootstrap-ServiceAccount.ps1` |
| `apiserver-<sanitized-cluster-name>` | `<ip>:<port>` e.g. `10.1.2.3:6443` | `Bootstrap-ServiceAccount.ps1` |

Cluster name sanitization: `$name -replace '[^a-zA-Z0-9-]','-'`

Prefixes are configurable via AA variables `AA-SaTokenPrefix` (default `satoken`) and `AA-ApiServerPrefix` (default `apiserver`).

---

## Automation Account variables

All variables are named `AA-*` and read via `Get-AutomationVariable`. Workers read them in
`Shard-RestartPods.ps1` and pass as explicit params to `Worker-RestartSingleCluster.ps1`
(Workers run as plain local scripts and cannot call `Get-AutomationVariable` directly).

| Variable | Type | Purpose |
|---|---|---|
| `AA-KeyVaultName` | Plain | Key Vault resource name |
| `AA-WorkspaceId` | Plain | Log Analytics workspace GUID |
| `AA-WorkspaceKey` | Encrypted | Log Analytics primary shared key |
| `AA-HybridWorkerGroup` | Plain | Hybrid Worker Group name |
| `AA-SaTokenPrefix` | Plain | KV secret prefix for SA tokens (`satoken`) |
| `AA-ApiServerPrefix` | Plain | KV secret prefix for API servers (`apiserver`) |
| `AA-SubscriptionIds` | Plain | Comma-separated subscription IDs to scan |
| `AA-AccountName` | Plain | Automation Account name (for ARM job polling URI) |
| `AA-ResourceGroup` | Plain | Automation Account resource group |

---

## State files (deployment artifacts — never commit)

Written by deployment scripts; consumed by subsequent scripts. **Never commit** — use `.example.json` stubs.

| File | Written by | Read by |
|---|---|---|
| `infra/infra-state.json` | `Deploy-Infrastructure.ps1` | `Deploy-LogicApp.ps1`, `Setup-HybridWorkerGroup.ps1` |
| `infra/hybrid-worker-state.json` | `Setup-HybridWorkerGroup.ps1` | Reference / manual ops |
| `infra/logic-app-state.json` | `Deploy-LogicApp.ps1` | Reference — contains trigger URL |

---

## Audit log schema (Log Analytics table: `AKSArcRestart_CL`)

```
TimeGenerated, ClusterName, SubscriptionId, ResourceGroup, Namespace,
WorkloadType, WorkloadName, Status, HttpStatus, DurationMs,
InitiatedBy, JobId, ShardId, ErrorDetail
```

`Status` values: `Started`, `Success`, `Failed`, `Skipped`, `NetworkError`

---

## PowerShell conventions

- Always open files with `Set-StrictMode -Version Latest` and `$ErrorActionPreference = "Stop"`
- Always include `#Requires -Version 5.1` (or `7.2` for PS7 runbooks)
- Parameters use `PascalCase`; always type-annotate; mark mandatory params with `[Parameter(Mandatory)]`
- Use PowerShell approved verbs (`Get-`, `Set-`, `Test-`, `Invoke-`, `Write-`, `New-`, `Remove-`)
- Color-coded `Write-Host` output: Cyan = section header, Yellow = in-progress, Green = success, Red = error, DarkGray = verbose detail
- Prefer `[System.Collections.Generic.List[T]]` over `@()` for arrays built in loops
- Use `[ordered]@{}` for hashtables that must preserve insertion order (e.g. audit records)
- Force TLS 1.2 at top of every file that makes HTTPS calls: `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`

---

## Error handling patterns

**Scripts** (Bootstrap, Rotate, Deploy): throw on any error. `$ErrorActionPreference = "Stop"` propagates all terminating errors.

**Worker runbook** (`Worker-RestartSingleCluster.ps1`): use the `Finish` helper pattern — always writes an audit record on success or failure, then `throw` to let the parent shard track the failure count:

```powershell
function Finish {
    param([string]$Status, [int]$Http = 0, [string]$Err = "")
    $auditRecord.Status     = $Status
    $auditRecord.HttpStatus = $Http
    $auditRecord.DurationMs = [Math]::Round((New-TimeSpan $startTime (Get-Date)).TotalMilliseconds)
    $auditRecord.ErrorDetail = $Err
    if ($wsId -and $wsKey) { Write-AuditLog ... }
}
```

**Shard runbook** (`Shard-RestartPods.ps1`): `$ErrorActionPreference = "Continue"` — one cluster failure must not stop the rest of the shard. Collect results in a `ConcurrentBag`.

---

## Bicep conventions

- Section comments: `// ------------- Section Name -------------`
- Each resource has a `@description()` on its parameters
- Role assignments use `guid(scope.id, principalName, roleId)` for deterministic names
- Subscription-scoped role assignments belong in the PS1 wrapper, not Bicep (Bicep requires a subscription-scoped deployment target)
- All resources that the PS1 wrapper consumes post-deploy must be in `output`

---

## Kubernetes YAML conventions

- All K8s objects created by this project carry labels: `app: azure-automation-restart` and `managed-by: arc-automation`
- Namespace for the SA and related objects: `kube-system`
- SA token Secret name: `automation-restart-token`; SA name: `automation-restart`
- ClusterRole is least-privilege: `patch` on `apps/deployments,statefulsets,daemonsets` only

---

## Testing

1. After bootstrap: `.\scripts\Test-SATokenAccess.ps1 -KeyVaultName <kv> -ClusterName <name>`
2. Before any destructive infra operation: use `-WhatIf` switch (supported by all `infra/` and `scripts/` scripts)
3. Master runbook smoke test: `coredns` deployment in `kube-system` (safe — it self-heals)
4. Logic App test: POST to trigger URL with `namespace=kube-system, workloadType=deployment, workloadName=coredns`

---

## Folder structure reference

```
infra/       Deployment scripts (Deploy-Infrastructure.ps1, Deploy-LogicApp.ps1, main.bicep)
             State files (*-state.json, gitignored)
k8s/         Kubernetes manifests (restart-sa.yaml)
logic-app/   ARM template for optional HTTP trigger (logicapp-template.json)
runbooks/    Azure Automation runbooks + Shared-Functions.ps1
scripts/     One-time ops: Bootstrap, Rotate tokens, Test, Cleanup
```
