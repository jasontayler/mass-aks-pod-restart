// main.bicep
// SA Token Pattern - Azure Infrastructure
// Deploys: Automation Account, Key Vault, Log Analytics Workspace, role assignments
// Called by: Deploy-Infrastructure.ps1 (which handles post-deploy variables + state file)

@description('Azure region for all resources')
param location string

@description('Name for the Azure Automation Account')
param automationAccountName string

@description('Name for the Key Vault (must be globally unique, 3-24 chars)')
param keyVaultName string

@description('Name for the Log Analytics Workspace')
param workspaceName string

@description('Name for the Hybrid Worker Group')
param hybridWorkerGroup string

// ---------------------------------------------------------------------------
// Automation Account (system-assigned managed identity)
// ---------------------------------------------------------------------------
resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
    disableLocalAuth: false
  }
}

// ---------------------------------------------------------------------------
// Hybrid Worker Group
// ---------------------------------------------------------------------------
resource hybridWorkerGroupRes 'Microsoft.Automation/automationAccounts/hybridRunbookWorkerGroups@2022-08-08' = {
  parent: automationAccount
  name: hybridWorkerGroup
  properties: {}
}

// ---------------------------------------------------------------------------
// Key Vault (RBAC mode, soft delete 7 days, purge protection)
// ---------------------------------------------------------------------------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Log Analytics Workspace (90 day retention)
// ---------------------------------------------------------------------------
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 90
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Role assignments
// Key Vault Secrets User → Automation Account MI  (read SA tokens at runtime)
// ---------------------------------------------------------------------------
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
resource kvSecretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, automationAccountName, kvSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// NOTE: Reader on subscription scope is granted by Deploy-Infrastructure.ps1
//       (subscription-scoped role assignments require a subscription-scoped
//        Bicep deployment -- handled in the PS1 wrapper for simplicity)

// ---------------------------------------------------------------------------
// Outputs (consumed by Deploy-Infrastructure.ps1 to write infra-state.json)
// ---------------------------------------------------------------------------
output automationAccountId string = automationAccount.id
output automationMiOid string = automationAccount.identity.principalId
output automationHybridServiceUrl string = automationAccount.properties.automationHybridServiceUrl
output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri
output workspaceId string = logAnalyticsWorkspace.properties.customerId
output workspaceResourceId string = logAnalyticsWorkspace.id
output hybridWorkerGroupName string = hybridWorkerGroupRes.name
