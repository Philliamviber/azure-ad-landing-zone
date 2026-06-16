# sentinel module — onboard Microsoft Sentinel onto the management workspace
# and enable baseline data connectors relevant to AD/identity threat hunting.

variable "log_analytics_workspace_id" { type = string }
variable "workspace_name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

# Sentinel = a solution layered on the Log Analytics workspace.
resource "azurerm_sentinel_log_analytics_workspace_onboarding" "this" {
  workspace_id                 = var.log_analytics_workspace_id
  customer_managed_key_enabled = false
}

# Security Events connector (Windows security log via AMA / DCR).
resource "azurerm_sentinel_data_connector_microsoft_threat_protection" "mtp" {
  name                       = "mtp-connector"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.this.workspace_id
}

# A starter scheduled analytics rule: AD replication / DCSync-style activity.
resource "azurerm_sentinel_alert_rule_scheduled" "dcsync" {
  name                       = "suspicious-directory-replication"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.this.workspace_id
  display_name               = "Directory replication rights granted (possible DCSync)"
  severity                   = "High"
  query_frequency            = "PT1H"
  query_period               = "PT1H"
  tactics                    = ["CredentialAccess"]

  query = <<-KQL
    SecurityEvent
    | where EventID == 4662
    | where Properties has "1131f6aa-9c07-11d1-f79f-00c04fc2dcd2" // DS-Replication-Get-Changes
       or Properties has "1131f6ad-9c07-11d1-f79f-00c04fc2dcd2"  // DS-Replication-Get-Changes-All
    | where Account !endswith "$"
    | project TimeGenerated, Computer, Account, Properties
  KQL
}

output "sentinel_workspace_id" {
  value = azurerm_sentinel_log_analytics_workspace_onboarding.this.workspace_id
}
