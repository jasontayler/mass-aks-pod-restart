# Security Notes — AKS Arc Fleet Pod Restart

This document records security design decisions, known trade-offs, and required operational
security practices for this project.

---

## 1. Committed secrets — IMMEDIATE ACTION REQUIRED

> **If you are reading this in a cloned repository that was previously public or shared,
> assume the following values have been exposed and rotate them immediately.**

### Logic App trigger URL

`infra/logic-app-state.json` previously contained the Logic App trigger URL including a
SAS signature (`sig=...`). This URL is a callable HTTPS endpoint that starts a fleet-wide
pod restart.

**Mitigation**: The `*-state.json` files are now gitignored. Rotate the trigger URL by
re-running `Deploy-LogicApp.ps1`, which regenerates the Logic App and issues a new SAS token.

```powershell
.\infra\Deploy-LogicApp.ps1
```

Store the new trigger URL in Key Vault, not in files or pipeline variables.

### Subscription and tenant identifiers

`infra-state.json` and `hybrid-worker-state.json` previously contained:
- Subscription ID
- Tenant ID
- Managed Identity Object ID
- Key Vault resource ID

These are now gitignored. While these identifiers alone do not grant access, they reduce
the effort required for reconnaissance. Treat them as internal identifiers — do not publish
them.

---

## 2. TLS certificate bypass in `Invoke-K8sRest`

```powershell
$h.ServerCertificateCustomValidationCallback =
    [System.Net.Http.HttpClientHandler]::DangerousAcceptAnyServerCertificateValidator
```

**Why this exists**: AKS Arc clusters on Azure Local use self-signed certificates issued by
the cluster's own CA. The Hybrid Worker machine is on-premises and does not have the cluster
CA in its trusted certificate store. Distributing and maintaining per-cluster CA certificates
across hundreds of on-prem worker machines is operationally impractical.

**Risk scope**: The bypass is scoped to the `HttpClient` instance inside `Invoke-K8sRest`.
It does not affect system-wide TLS settings. The connection is still TLS-encrypted; the
bypass only skips certificate *chain validation*, not encryption.

**Mitigations in place**:
- The worker machine is on the same LAN as the clusters (private network, no public exposure).
- Authentication is via a short-lived SA token fetched from Azure Key Vault — an attacker
  performing a MitM attack would still need a valid SA token to issue PATCH requests.
- Network segmentation: Hybrid Worker machines should be on a VLAN that restricts which
  IP:port combinations they can reach.

**Future improvement**: Distribute cluster CA certificates to Hybrid Workers via GPO or
Azure Arc Connected Machine extension, then remove the bypass and pin the CA.

---

## 3. Service account least privilege

The `automation-restart` Kubernetes service account has the minimum permissions needed:

```yaml
rules:
- apiGroups: ["apps"]
  resources: ["deployments", "statefulsets", "daemonsets"]
  verbs: ["get", "list", "patch"]
- apiGroups: [""]
  resources: ["namespaces", "pods"]
  verbs: ["get", "list"]
```

It **cannot**:
- Delete or create workloads
- Access Secrets, ConfigMaps, or any other resource type
- Access any non-`apps` API group beyond listing namespaces and pods

If you need to extend the ClusterRole, document the business justification in `k8s/restart-sa.yaml`
as a comment on the added rule.

---

## 4. Key Vault access model

Access to Key Vault uses Azure RBAC (not access policies). The Automation Account's
system-assigned Managed Identity is granted `Key Vault Secrets User` on the vault.

| Principal | Role | Scope | Granted by |
|---|---|---|---|
| Automation Account MI | Key Vault Secrets User | Key Vault | `main.bicep` |
| Hybrid Worker MI | Key Vault Secrets User | Key Vault | Manual — see Step 2 in README |
| Logic App MI | Automation Operator | Automation Account | `Deploy-LogicApp.ps1` |

No human identity is granted standing access to Key Vault secrets. Access for administrators
should be Just-In-Time via Azure PIM (Privileged Identity Management).

---

## 5. SA token rotation

SA tokens are long-lived (they do not expire unless the cluster CA rotates). Rotate annually:

```powershell
.\scripts\Rotate-ServiceAccountTokens.ps1 `
    -KeyVaultName "kv-aksarc-automation" `
    -AutoDiscover       # or -ClusterName + -KubeconfigPath for single cluster
```

The old KV secret version is retained for 7 days (Key Vault soft-delete) for rollback.
Schedule this via an Azure Automation Schedule on the Hybrid Worker.

**Trigger rotation immediately if**:
- A Hybrid Worker machine is decommissioned or suspected compromised.
- The Key Vault is accessed by an unexpected principal.
- The `kube-system` namespace on any cluster is breached.

---

## 6. Logic App HTTP trigger

The Logic App trigger URL contains a SAS signature that never expires by default.

Operational security rules:
- **Do not embed the trigger URL** in scripts, pipelines, or documentation.
- **Store it in Key Vault** after initial deploy and fetch at call time.
- **Put APIM or Easy Auth in front** of the Logic App if the trigger must be called by humans
  — this enables AAD authentication and audit logging via the `X-MS-CLIENT-PRINCIPAL-NAME` header.
- **Rotate** the URL by re-running `Deploy-LogicApp.ps1` if it is ever exposed.

---

## 7. Azure Automation workspace key

`AA-WorkspaceKey` is stored as an **encrypted** Automation Account variable. It is used to
write audit records to Log Analytics via the HTTP Data Collector API.

This key does not grant read access to Log Analytics — it is write-only for data ingestion.
Still, if it is compromised an attacker could inject false audit records. Rotate it via the
Log Analytics workspace in Azure Portal if compromise is suspected.

---

## 8. Hybrid Worker machine security

The Hybrid Worker machine has access to:
- Azure Key Vault (via its Managed Identity)
- All AKS Arc cluster API servers on the LAN (via SA tokens from KV)
- Log Analytics (via the workspace key from AA)

Recommended hardening:
- Join the worker machine to Azure Arc (enables Defender for Servers).
- Apply Windows Update regularly.
- Restrict outbound access to: Key Vault FQDN, Azure Automation JRDS endpoints, Log Analytics endpoint.
- Restrict inbound access: block all inbound (the worker initiates all connections).
- Store `C:\Scripts\` as read-only for non-admin accounts.
- Enable Windows Defender and configure exclusions only for well-known runbook paths.
