# azure-firewall module — Azure Firewall Premium with IDPS (deep packet
# inspection) mediating all spoke-to-spoke (DC-to-DC) and PAW traffic.
#
# Premium tier unlocks the IDPS engine (signature-based intrusion detection +
# prevention) and TLS inspection — this is the "deep packet inspection between
# the two" the design calls for. The firewall policy below:
#   * Turns IDPS to Deny (actively blocks malicious signatures).
#   * Permits ONLY the AD replication / DCOM / RPC port set between DC1<->DC2.
#   * Permits WinRM from the PAW plane to the DCs.
#   * Denies everything else implicitly (no broad allow rule).

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "sku_tier" {
  type    = string
  default = "Premium"
}
variable "firewall_subnet_id" { type = string }
variable "log_analytics_workspace_id" { type = string }
variable "dc1_address_space" { type = list(string) }
variable "dc2_address_space" { type = list(string) }
variable "paw_address_space" { type = list(string) }
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  # AD DS replication + authentication + DCOM/RPC port set (DC <-> DC).
  ad_tcp_ports = [
    "53",    # DNS
    "88",    # Kerberos
    "135",   # RPC endpoint mapper (DCOM)
    "139",   # NetBIOS session
    "389",   # LDAP
    "445",   # SMB
    "464",   # Kerberos password change
    "636",   # LDAPS
    "3268",  # Global Catalog
    "3269",  # Global Catalog SSL
    "9389",  # AD DS Web Services (ADWS)
    "49152-65535", # RPC dynamic / DCOM high ports (replication, DRSUAPI)
  ]
  ad_udp_ports = [
    "53",  # DNS
    "88",  # Kerberos
    "123", # NTP (time sync is critical for Kerberos)
    "389", # LDAP ping / CLDAP
    "464", # Kerberos password change
  ]
}

resource "azurerm_public_ip" "fw" {
  name                = "pip-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# ---- Firewall Policy (Premium) with IDPS ----------------------------------
resource "azurerm_firewall_policy" "this" {
  name                = "afwp-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = var.sku_tier
  tags                = var.tags

  threat_intelligence_mode = "Deny"

  dynamic "intrusion_detection" {
    for_each = var.sku_tier == "Premium" ? [1] : []
    content {
      mode = "Deny" # IDPS actively blocks malicious signatures (DPI)
    }
  }
}

# ---- Rule collection group: AD replication between the two DCs -------------
resource "azurerm_firewall_policy_rule_collection_group" "ad" {
  name               = "rcg-active-directory"
  firewall_policy_id = azurerm_firewall_policy.this.id
  priority           = 200

  network_rule_collection {
    name     = "nrc-dc-to-dc-replication"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "dc1-to-dc2-tcp"
      protocols             = ["TCP"]
      source_addresses      = var.dc1_address_space
      destination_addresses = var.dc2_address_space
      destination_ports     = local.ad_tcp_ports
    }
    rule {
      name                  = "dc2-to-dc1-tcp"
      protocols             = ["TCP"]
      source_addresses      = var.dc2_address_space
      destination_addresses = var.dc1_address_space
      destination_ports     = local.ad_tcp_ports
    }
    rule {
      name                  = "dc1-to-dc2-udp"
      protocols             = ["UDP"]
      source_addresses      = var.dc1_address_space
      destination_addresses = var.dc2_address_space
      destination_ports     = local.ad_udp_ports
    }
    rule {
      name                  = "dc2-to-dc1-udp"
      protocols             = ["UDP"]
      source_addresses      = var.dc2_address_space
      destination_addresses = var.dc1_address_space
      destination_ports     = local.ad_udp_ports
    }
  }

  network_rule_collection {
    name     = "nrc-paw-to-dc-winrm"
    priority = 300
    action   = "Allow"

    rule {
      name                  = "paw-to-dcs-winrm"
      protocols             = ["TCP"]
      source_addresses      = var.paw_address_space
      destination_addresses = concat(var.dc1_address_space, var.dc2_address_space)
      destination_ports     = ["5985", "5986", "3389"] # WinRM (HTTP/HTTPS) + RDP fallback
    }
  }
}

# ---- The firewall ----------------------------------------------------------
resource "azurerm_firewall" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "AZFW_VNet"
  sku_tier            = var.sku_tier
  firewall_policy_id  = azurerm_firewall_policy.this.id
  tags                = var.tags

  ip_configuration {
    name                 = "fw-ipconfig"
    subnet_id            = var.firewall_subnet_id
    public_ip_address_id = azurerm_public_ip.fw.id
  }
}

resource "azurerm_monitor_diagnostic_setting" "fw" {
  name                       = "afw-diag"
  target_resource_id         = azurerm_firewall.this.id
  log_analytics_workspace_id = var.log_analytics_workspace_id

  enabled_log { category_group = "allLogs" }
  metric { category = "AllMetrics" }
}

output "private_ip" { value = azurerm_firewall.this.ip_configuration[0].private_ip_address }
output "policy_id" { value = azurerm_firewall_policy.this.id }
output "firewall_id" { value = azurerm_firewall.this.id }
