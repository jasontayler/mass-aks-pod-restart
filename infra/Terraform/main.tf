terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.110"
    }
  }

  # Uncomment to store state in Azure Blob Storage (recommended for teams):
  # backend "azurerm" {
  #   resource_group_name  = "rg-terraform-state"
  #   storage_account_name = "sttfstate"
  #   container_name       = "tfstate"
  #   key                  = "aksarc-automation.tfstate"
  # }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
  }
}

data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "main" {
  name     = var.resource_group
  location = var.location
}

# ---------------------------------------------------------------------------
# Automation Account (system-assigned managed identity)
# ---------------------------------------------------------------------------

resource "azurerm_automation_account" "main" {
  name                          = var.automation_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  sku_name                      = "Basic"
  public_network_access_enabled = true
  local_authentication_enabled  = true

  identity {
    type = "SystemAssigned"
  }
}

# ---------------------------------------------------------------------------
# Hybrid Worker Group
# ---------------------------------------------------------------------------

resource "azurerm_automation_hybrid_runbook_worker_group" "main" {
  name                    = var.hybrid_worker_group
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
}

# ---------------------------------------------------------------------------
# Key Vault (RBAC mode, soft delete 7 days, purge protection)
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "main" {
  name                          = var.key_vault_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  enable_rbac_authorization     = true
  soft_delete_retention_days    = 7
  purge_protection_enabled      = true
  public_network_access_enabled = true
}

# ---------------------------------------------------------------------------
# Log Analytics Workspace (90-day retention)
# ---------------------------------------------------------------------------

resource "azurerm_log_analytics_workspace" "main" {
  name                = var.workspace_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 90
}

# ---------------------------------------------------------------------------
# Role assignments
# ---------------------------------------------------------------------------

# Key Vault Secrets User -> Automation Account MI (read SA tokens at runtime)
resource "azurerm_role_assignment" "aa_kv_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_automation_account.main.identity[0].principal_id
}

# Reader on each cluster subscription so Resource Graph can enumerate clusters
resource "azurerm_role_assignment" "cluster_sub_reader" {
  for_each             = toset(var.managed_cluster_sub_ids)
  scope                = "/subscriptions/${each.value}"
  role_definition_name = "Reader"
  principal_id         = azurerm_automation_account.main.identity[0].principal_id
}

# ---------------------------------------------------------------------------
# Automation Account variables
# ---------------------------------------------------------------------------

locals {
  # Comma-separated subscription list for AA-SubscriptionIds.
  # Uses managed_cluster_sub_ids if provided, otherwise the primary subscription.
  subscription_ids_value = length(var.managed_cluster_sub_ids) > 0 ? join(",", var.managed_cluster_sub_ids) : var.subscription_id
}

resource "azurerm_automation_variable_string" "kv_name" {
  name                    = "AA-KeyVaultName"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = var.key_vault_name
  encrypted               = false
}

resource "azurerm_automation_variable_string" "workspace_id" {
  name                    = "AA-WorkspaceId"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = azurerm_log_analytics_workspace.main.workspace_id
  encrypted               = false
}

resource "azurerm_automation_variable_string" "workspace_key" {
  name                    = "AA-WorkspaceKey"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = azurerm_log_analytics_workspace.main.primary_shared_key
  encrypted               = true
}

resource "azurerm_automation_variable_string" "hybrid_worker_group" {
  name                    = "AA-HybridWorkerGroup"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = var.hybrid_worker_group
  encrypted               = false
}

resource "azurerm_automation_variable_string" "sa_token_prefix" {
  name                    = "AA-SaTokenPrefix"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = "satoken"
  encrypted               = false
}

resource "azurerm_automation_variable_string" "api_server_prefix" {
  name                    = "AA-ApiServerPrefix"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = "apiserver"
  encrypted               = false
}

resource "azurerm_automation_variable_string" "subscription_ids" {
  name                    = "AA-SubscriptionIds"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = local.subscription_ids_value
  encrypted               = false
}

resource "azurerm_automation_variable_string" "account_name" {
  name                    = "AA-AccountName"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = var.automation_name
  encrypted               = false
}

resource "azurerm_automation_variable_string" "account_resource_group" {
  name                    = "AA-ResourceGroup"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = var.resource_group
  encrypted               = false
}

resource "azurerm_automation_variable_string" "environment_guard" {
  name                    = "AA-EnvironmentGuard"
  resource_group_name     = azurerm_resource_group.main.name
  automation_account_name = azurerm_automation_account.main.name
  value                   = var.environment_guard
  encrypted               = false
}
