variable "subscription_id" {
  type        = string
  description = "Azure subscription ID where the Automation Account and supporting resources are deployed."
}

variable "resource_group" {
  type        = string
  description = "Name of the resource group to create."
  default     = "rg-aksarc-automation"
}

variable "location" {
  type        = string
  description = "Azure region for all resources."
  default     = "australiaeast"
}

variable "automation_name" {
  type        = string
  description = "Name for the Azure Automation Account."
  default     = "aa-aksarc-restart"
}

variable "key_vault_name" {
  type        = string
  description = "Globally unique name for the Key Vault (3-24 chars, alphanumeric and hyphens only)."
}

variable "workspace_name" {
  type        = string
  description = "Name for the Log Analytics Workspace."
  default     = "law-aksarc-restart"
}

variable "hybrid_worker_group" {
  type        = string
  description = "Name of the Hybrid Runbook Worker Group."
  default     = "AKSArcWorkers"
}

variable "managed_cluster_sub_ids" {
  type        = list(string)
  description = "Subscription IDs containing AKS Arc clusters. The AA Managed Identity is granted Reader on each for Resource Graph queries."
  default     = []
}

variable "environment_guard" {
  type        = string
  description = "Optional KQL where-clause injected into every Resource Graph query to restrict cluster scope. E.g. \"| where tags.environment == 'prod'\". Leave empty to allow all clusters in managed_cluster_sub_ids."
  default     = ""
}
