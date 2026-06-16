# key-vault module — RBAC-delegated secret store for the landing zone.
#
# Design notes:
#  * enable_rbac_authorization = true  -> NO access policies; all access is via
#    Azure RBAC role assignments ("delegation"). This is the modern, auditable
#    model and lets each DC's managed identity get scoped, least-privilege reads.
#  * Public network access disabled; soft-delete + purge protection on.
#  * Diagnostic logs flow to Log Analytics for Sentinel coverage.

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tenant_id" { type = string }
variable "log_analytics_workspace_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  tenant_id           = var.tenant_id
  sku_name            = "standard"

  # RBAC delegation instead of access policies.
  enable_rbac_authorization = true

  # Hardening.
  purge_protection_enabled      = true
  soft_delete_retention_days    = 90
  public_network_access_enabled = false
  enabled_for_deployment        = false # no classic VM cert injection path
  enabled_for_disk_encryption   = true

  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
  }

  tags = var.tags
}

# The deploying principal needs Secrets Officer to seed initial secrets.
resource "azurerm_role_assignment" "deployer_secrets_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Diagnostics -> Log Analytics (audit every secret access for Sentinel).
resource "azurerm_monitor_diagnostic_setting" "kv" {
  name                       = "kv-diag"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category = "AuditEvent" }
  enabled_log { category = "AzurePolicyEvaluationDetails" }
  metric { category = "AllMetrics" }
}

output "id" { value = azurerm_key_vault.this.id }
output "uri" { value = azurerm_key_vault.this.vault_uri }
output "name" { value = azurerm_key_vault.this.name }
