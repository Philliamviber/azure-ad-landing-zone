# log-analytics module — management-plane workspace + Windows DCR for the DCs.

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "retention_in_days" {
  type    = number
  default = 90
}
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "PerGB2018" # pay-as-you-go; cost-optimized for low volume
  retention_in_days   = var.retention_in_days
  daily_quota_gb      = 5 # cap ingestion to control cost; raise as needed
  tags                = var.tags
}

# Data Collection Rule: ship Windows Security + System + AD event logs and
# performance counters from the DCs to the workspace via Azure Monitor Agent.
resource "azurerm_monitor_data_collection_rule" "windows" {
  name                = "dcr-windows-dc-events"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.this.id
      name                  = "law-dest"
    }
  }

  data_flow {
    streams      = ["Microsoft-SecurityEvent", "Microsoft-Event"]
    destinations = ["law-dest"]
  }

  data_sources {
    windows_event_log {
      name    = "security-and-ad-events"
      streams = ["Microsoft-SecurityEvent", "Microsoft-Event"]
      # Security auditing + Directory Service + DNS Server + System.
      x_path_queries = [
        "Security!*",
        "System!*",
        "Directory Service!*",
        "DNS Server!*",
        "Microsoft-Windows-Sysmon/Operational!*",
      ]
    }
  }
}

output "workspace_id" { value = azurerm_log_analytics_workspace.this.id }
output "workspace_name" { value = azurerm_log_analytics_workspace.this.name }
output "windows_dcr_id" { value = azurerm_monitor_data_collection_rule.windows.id }
