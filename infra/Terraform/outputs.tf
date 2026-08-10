output "automation_account_id" {
  description = "Resource ID of the Automation Account."
  value       = azurerm_automation_account.main.id
}

output "automation_mi_principal_id" {
  description = "Object ID of the Automation Account system-assigned managed identity. Grant this 'Key Vault Secrets User' on any additional Key Vaults."
  value       = azurerm_automation_account.main.identity[0].principal_id
}

output "automation_hybrid_service_url" {
  description = "Hybrid Service URL needed when registering Hybrid Runbook Workers via az CLI."
  value       = azurerm_automation_account.main.hybrid_service_url
}

output "key_vault_id" {
  description = "Resource ID of the Key Vault."
  value       = azurerm_key_vault.main.id
}

output "key_vault_uri" {
  description = "URI of the Key Vault (pass as -KeyVaultName to Bootstrap-ServiceAccount.ps1)."
  value       = azurerm_key_vault.main.vault_uri
}

output "workspace_id" {
  description = "Log Analytics workspace GUID. Stored in AA-WorkspaceId automatically."
  value       = azurerm_log_analytics_workspace.main.workspace_id
}

output "workspace_resource_id" {
  description = "Full resource ID of the Log Analytics Workspace."
  value       = azurerm_log_analytics_workspace.main.id
}

output "hybrid_worker_group_name" {
  description = "Name of the Hybrid Runbook Worker Group."
  value       = azurerm_automation_hybrid_runbook_worker_group.main.name
}
