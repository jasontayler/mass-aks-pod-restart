# AKS Arc Fleet Pod Restart — SA Token Pattern

Mass restart of Kubernetes workloads across 800+ AKS Arc clusters on Azure Local (HCI),
using Kubernetes Service Account tokens stored in Azure Key Vault.

---

## Why this approach

AKS Arc workload clusters on Azure Local do **not** have Azure RBAC enabled by default.
The Kubernetes API server only trusts:
- Service account tokens (signed by the cluster's own key)
- Client certificates

Azure AD / Managed Identity tokens are rejected at the K8s API level.

The SA Token Pattern solves this by:
1. Storing a minimal service account token per cluster in Key Vault (bootstrap, one-time)
2. Using the Hybrid Worker's Managed Identity to fetch tokens from Key Vault at runtime
3. Calling the K8s API directly via REST — no kubectl, no Az modules needed at runtime

---

## Architecture

```
BOOTSTRAP (one-time per cluster, from HCI host)
  HCI Host
    Get-AksHciCredential  →  admin kubeconfig
    kubectl apply restart-sa.yaml  →  ServiceAccount + ClusterRole (restart-only)
    Extract SA token from Secret
    Write to Key Vault:
      satoken-<clustername>    = SA JWT token
      apiserver-<clustername>  = "10.x.x.x:6443"

RUNTIME (every restart job)
  Azure Automation (cloud)
    Master-FleetRestart.ps1
      Resource Graph  →  enumerate all Connected clusters
      Shard into 50-cluster chunks
      Start-AutomationRunbook Shard-RestartPods.ps1 x N  (parallel)

  Hybrid Worker (on-prem, same LAN)
    Shard-RestartPods.ps1  (50 parallel threads)
      Worker-RestartSingleCluster.ps1 per cluster:
        himds  →  KV token
        Key Vault  →  SA token + API server IP
        PATCH https://<ip>:6443/apis/apps/v1/namespaces/<ns>/<type>/<name>
        Write audit record to Log Analytics

AUDIT
  Log Analytics table: AKSArcRestart_CL
  Fields: cluster, namespace, workload, status, duration, initiatedBy, jobId

┌─────────────────────────────────────────────────────────────────┐
│                         AZURE (Control Plane)                    │
│                                                                   │
│  ┌─────────────────┐    ┌──────────────────┐    ┌─────────────┐ │
│  │ Azure Automation │    │   Key Vault       │    │    Log      │ │
│  │                  │    │                   │    │  Analytics  │ │
│  │ Master runbook   │    │ satoken-cluster1  │    │             │ │
│  │ Shard runbooks   │    │ satoken-cluster2  │    │ Audit table │ │
│  │ Hybrid Workers   │    │ apiserver-cluster1│    │ Alert rules │ │
│  └────────┬─────────┘    │ apiserver-cluster2│    └──────┬──────┘ │
│           │              └────────┬──────────┘           │        │
└───────────┼─────────────────────┼────────────────────────┼────────┘
            │ himds token         │ himds token             │ REST
            ▼                     ▼                         │
┌─────────────────────────────────────────────────────────┐ │
│               ON-PREMISES (Hybrid Worker)                │ │
│                                                          │ │
│  Worker machine (Arc-enrolled, same LAN as clusters)     │ │
│                                                          │ │
│  1. Get ARM token (himds)                                │ │
│  2. Get KV token (himds → vault.azure.net)               │ │
│  3. Fetch SA token from Key Vault                        │ │
│  4. PATCH /apis/apps/v1/namespaces/{ns}/{type}/{name}    ├─┘
│     Authorization: Bearer <SA token>                     │
│  5. Send audit log → Log Analytics                       │
└──────────────────────────┬───────────────────────────────┘
                           │ direct REST :6443
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                  ▼
    Cluster 1         Cluster 2         Cluster N
   10.x.x.1:6443    10.x.x.2:6443    10.x.x.N:6443
   SA token A       SA token B       SA token N
---

```

## Folder structure

```
SA-Token-Pattern/
  infra/
    Deploy-Infrastructure.ps1     # Creates AA, KV, Log Analytics, roles
    Deploy-LogicApp.ps1           # (Optional) Deploys the Logic App HTTP trigger
    main.bicep                    # Bicep template for core infra
    infra-state.json              # Written by Deploy-Infrastructure.ps1
    logic-app-state.json          # Written by Deploy-LogicApp.ps1 (trigger URL here)
  k8s/
    restart-sa.yaml               # SA + ClusterRole manifest (apply to every cluster)
  logic-app/
    logicapp-template.json        # ARM template: HTTP trigger → AA job → poll → respond
  runbooks/
    Shared-Functions.ps1          # Get-HimdsToken, Get-KvSecret, Invoke-K8sRest, Write-AuditLog
    Master-FleetRestart.ps1       # Cloud runbook — orchestrates fleet
    Shard-RestartPods.ps1         # Hybrid Worker — parallel shard
    Worker-RestartSingleCluster.ps1  # Hybrid Worker — single cluster REST call
  scripts/
    Bootstrap-ServiceAccount.ps1  # One-time: apply SA, store token in KV
    Rotate-ServiceAccountTokens.ps1  # Annual: rotate token, update KV
    Test-SATokenAccess.ps1        # Smoke test after bootstrap
    Cleanup-AzureResources.ps1    # Remove old approach resources
```

---

## Step-by-step setup

### Step 0 — Clean up previous approach (if needed)

```powershell
.\scripts\Cleanup-AzureResources.ps1 `
  -SubscriptionId "e858a6b1-b4df-4533-98bf-8af3688e5f01" `
  -RemoveRoleAssignments `
  -WhatIf   # preview first
```

### Step 1 — Deploy Azure infrastructure

```powershell
.\infra\Deploy-Infrastructure.ps1 `
  -SubscriptionId     "e858a6b1-b4df-4533-98bf-8af3688e5f01" `
  -ResourceGroup      "rg-aksarc-automation" `
  -Location           "australiaeast" `
  -AutomationName     "aa-aksarc-restart" `
  -KeyVaultName       "kv-aksarc-automation" `
  -WorkspaceName      "law-aksarc-restart" `
  -HybridWorkerGroup  "AKSArcWorkers" `
  -ManagedClusterSubs "e858a6b1-..."
```

### Step 2 — Register Hybrid Worker(s)

Each on-prem Windows machine that sits on the same LAN as your clusters:

```powershell
# On each Hybrid Worker machine:
# 1. Install Azure Connected Machine agent (Arc-enrolls the machine)
# 2. Register as Hybrid Runbook Worker:
az automation hrwg hrw create `
  --resource-group rg-aksarc-automation `
  --automation-account-name aa-aksarc-restart `
  --hybrid-runbook-worker-group-name AKSArcWorkers `
  --name <worker-name> `
  --worker-type HybridV2

# 3. Grant KV Secrets User to the worker's managed identity:
az role assignment create `
  --role "Key Vault Secrets User" `
  --assignee-object-id <worker-mi-oid> `
  --scope "/subscriptions/.../vaults/kv-aksarc-automation"
```

### Step 3 — Bootstrap service accounts (from HCI host)

Run on each AzureStackHCI host that manages clusters:

```powershell
# Single cluster (if you have admin kubeconfig):
.\scripts\Bootstrap-ServiceAccount.ps1 `
  -KeyVaultName   "kv-aksarc-automation" `
  -ClusterName    "az-nuc-aks01" `
  -KubeconfigPath "C:\admin-kubeconfigs\az-nuc-aks01.yaml"

# All clusters on this HCI host (auto-discover):
.\scripts\Bootstrap-ServiceAccount.ps1 `
  -KeyVaultName "kv-aksarc-automation" `
  -AutoDiscover
```

### Step 4 — Verify on Hybrid Worker

```powershell
.\scripts\Test-SATokenAccess.ps1 `
  -KeyVaultName "kv-aksarc-automation" `
  -ClusterName  "az-nuc-aks01" `
  -Namespace    "default"

# Test an actual restart:
.\scripts\Test-SATokenAccess.ps1 `
  -KeyVaultName "kv-aksarc-automation" `
  -ClusterName  "az-nuc-aks01" `
  -Namespace    "default" `
  -TestRestart `
  -WorkloadType "deployment" `
  -WorkloadName "my-app"
```

### Step 5 — Import runbooks and trigger fleet restart

```powershell
# Import runbooks via az CLI or Azure Portal
# Then trigger:
Start-AzAutomationRunbook `
  -AutomationAccountName "aa-aksarc-restart" `
  -ResourceGroupName     "rg-aksarc-automation" `
  -Name                  "Master-FleetRestart" `
  -Parameters @{
      Namespace    = "production"
      WorkloadType = "statefulset"
      WorkloadName = "my-app"
  }
```

---

### Step 6 (Optional) — Deploy Logic App HTTP trigger

Provides an HTTPS endpoint so operators (or pipelines) can trigger fleet restarts without portal access.

```powershell
# From SA-Token-Pattern/infra/:
.\Deploy-LogicApp.ps1

# Custom name:
.\Deploy-LogicApp.ps1 -LogicAppName "logic-aksarc-restart-prod"
```

Reads `infra-state.json` automatically. After deploy:

- The trigger URL is printed to the console and saved in `infra/logic-app-state.json`.
- Treat the trigger URL as a secret (it contains a SAS token). Store it in Key Vault or behind APIM.

**Example call:**

```bash
curl -X POST "<trigger-url from logic-app-state.json>" \
  -H "Content-Type: application/json" \
  -d '{
    "namespace":     "production",
    "workloadType":  "statefulset",
    "workloadName":  "my-app",
    "clusterFilter": "| where tags.environment == '\''prod'\''",
    "initiatedBy":   "jane.doe@contoso.com"
  }'
```

**Response fields:**

| Field | Description |
|---|---|
| `jobGuid` | Azure Automation job GUID |
| `jobStatus` | `Completed` \| `Failed` \| `Stopped` |
| `jobStartTime` / `jobEndTime` | ISO 8601 timestamps |
| `namespace` / `workloadType` / `workloadName` | Echo of request params |
| `output` | Full runbook output stream (fleet summary, error list) |

HTTP `200` = job Completed. HTTP `500` = job Failed, Stopped, or timed out (Logic App waits up to 35 minutes).

**Architecture notes:**
- No API connector or manual portal authorisation required.
- Logic App uses a System-Assigned Managed Identity with `Automation Operator` role on the AA (assigned by `Deploy-LogicApp.ps1`).
- The `initiatedBy` field defaults to the AAD principal name from the `X-MS-CLIENT-PRINCIPAL-NAME` header (populated when the caller is AAD-authenticated via APIM or Easy Auth).

---

## Key Vault secrets layout

| Secret name | Value | Purpose |
|---|---|---|
| `satoken-az-nuc-aks01` | SA JWT token | Auth to cluster K8s API |
| `apiserver-az-nuc-aks01` | `10.10.10.26:6443` | API server address |
| `satoken-az-nuc-aks02` | SA JWT token | ... |
| `apiserver-az-nuc-aks02` | `10.10.10.27:6443` | ... |

One pair per cluster. Up to 25,000 secrets per Key Vault (well within 800 cluster limit).

---

## Service Account permissions

The SA has the minimum RBAC needed:

| Resource | Verbs |
|---|---|
| deployments, statefulsets, daemonsets | get, list, **patch** |
| namespaces, pods | get, list |

Cannot: delete pods, create resources, read secrets, exec into pods, modify RBAC.

---

## Token rotation (annual)

```powershell
# Single cluster:
.\scripts\Rotate-ServiceAccountTokens.ps1 `
  -KeyVaultName   "kv-aksarc-automation" `
  -ClusterName    "az-nuc-aks01" `
  -KubeconfigPath "C:\admin-kubeconfigs\az-nuc-aks01.yaml"

# All clusters (from HCI host):
.\scripts\Rotate-ServiceAccountTokens.ps1 `
  -KeyVaultName "kv-aksarc-automation" `
  -AutoDiscover
```

Previous KV secret versions are retained (7-day soft delete) for rollback.

---

## Audit queries (Log Analytics)

```kusto
// All restarts in last 24 hours
AKSArcRestart_CL
| where TimeGenerated > ago(24h)
| summarize Total=count(), Success=countif(Status_s=="Success"), Failed=countif(Status_s!="Success")
  by bin(TimeGenerated, 1h)

// Failed clusters
AKSArcRestart_CL
| where Status_s != "Success"
| project TimeGenerated, ClusterName_s, WorkloadName_s, HttpStatus_d, ErrorDetail_s

// Average restart duration by cluster
AKSArcRestart_CL
| where Status_s == "Success"
| summarize avg(DurationMs_d) by ClusterName_s | sort by avg_DurationMs_d desc

// All restart jobs: success/failure counts (last 24h)
AKSArcRestart_CL
| where TimeGenerated > ago(24h)
| summarize
    Success = countif(Status_s == "Success"),
    Failed  = countif(Status_s != "Success"),
    Total   = count()
  by JobId_s, WorkloadName_s
| order by Total desc

// Job counts by workload name (last 24h)
AKSArcRestart_CL
| where TimeGenerated > ago(24h)
| summarize
    TotalJobs = count(),
    Succeeded = countif(Status_s == "Success"),
    Failed    = countif(Status_s != "Success"),
    LastRun   = max(TimeGenerated)
  by WorkloadName_s
| order by TotalJobs desc

// Jobs submitted by user — success and failure counts (last 24h)
AKSArcRestart_CL
| where TimeGenerated > ago(24h)
| summarize
    TotalJobs = dcount(JobId_s),
    Succeeded = countif(Status_s == "Success"),
    Failed    = countif(Status_s != "Success"),
    LastSubmitted = max(TimeGenerated)
  by InitiatedBy_s
| order by TotalJobs desc
```

---

## Performance estimate

| Metric | Value |
|---|---|
| Per-cluster REST call | ~100-200ms |
| Parallel per shard (50 clusters) | ~200-400ms |
| 800 clusters / 16 shards | ~3-6 seconds total |
| Key Vault secret fetch | ~50ms (cached per shard) |

---

## Notes

- **Token per cluster is mandatory** — SA tokens are cryptographically bound to the signing cluster's key. A token from Cluster A cannot authenticate to Cluster B.
- **No kubectl binary needed at runtime** — only for bootstrap and rotation (HCI host).
- **Hybrid Worker machine identity** needs `Key Vault Secrets User` — this is the only Azure role needed at runtime.
- **Bootstrap requires admin kubeconfig** — available via `Get-AksHciCredential` on the HCI host, or `az aksarc get-credentials --admin` from a machine with Contributor on the HCS resource.
