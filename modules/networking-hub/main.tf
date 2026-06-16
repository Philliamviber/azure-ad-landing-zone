# networking-hub module — connectivity hub VNet.
#
# Subnets:
#   AzureFirewallSubnet  (/26 required name) -> Azure Firewall Premium
#   AzureBastionSubnet   (/26 required name) -> Azure Bastion
#   GatewaySubnet        (reserved for future ER/VPN, optional)
#
# All spoke-to-spoke traffic is forced through the firewall (see UDRs in spokes).

variable "name_prefix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "address_space" { type = list(string) }
variable "log_analytics_workspace_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.address_space
  tags                = var.tags
}

# Azure Firewall requires a subnet literally named "AzureFirewallSubnet" (>= /26).
# newbits=4 on the /22 hub yields /26 blocks: 10.10.0.0/26, 10.10.0.64/26, ...
resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.address_space[0], 4, 0)] # 10.10.0.0/26
}

# Azure Bastion requires a subnet literally named "AzureBastionSubnet" (>= /26).
resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.address_space[0], 4, 1)] # 10.10.0.64/26
}

resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.address_space[0], 4, 2)] # 10.10.0.128/26
}

resource "azurerm_monitor_diagnostic_setting" "vnet" {
  name                       = "vnet-hub-diag"
  target_resource_id         = azurerm_virtual_network.hub.id
  log_analytics_workspace_id = var.log_analytics_workspace_id
  metric { category = "AllMetrics" }
}

output "vnet_id" { value = azurerm_virtual_network.hub.id }
output "vnet_name" { value = azurerm_virtual_network.hub.name }
output "firewall_subnet_id" { value = azurerm_subnet.firewall.id }
output "bastion_subnet_id" { value = azurerm_subnet.bastion.id }
output "bastion_subnet_prefix" { value = azurerm_subnet.bastion.address_prefixes[0] }
