# peering submodule — bidirectional hub <-> spoke VNet peerings.
# Spokes do NOT peer with each other; spoke-to-spoke transits the hub firewall
# (forced tunneling via UDR), which is where deep packet inspection happens.

variable "hub_vnet_id" { type = string }
variable "hub_vnet_name" { type = string }
variable "hub_rg_name" { type = string }

variable "spokes" {
  description = "Map of spoke key => { vnet_id, vnet_name, rg }."
  type = map(object({
    vnet_id   = string
    vnet_name = string
    rg        = string
  }))
}

# Hub -> spoke
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  for_each = var.spokes

  name                         = "peer-hub-to-${each.key}"
  resource_group_name          = var.hub_rg_name
  virtual_network_name         = var.hub_vnet_name
  remote_virtual_network_id    = each.value.vnet_id
  allow_forwarded_traffic      = true # required so firewall can relay spoke traffic
  allow_gateway_transit        = true
  allow_virtual_network_access = true
}

# Spoke -> hub
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  for_each = var.spokes

  name                         = "peer-${each.key}-to-hub"
  resource_group_name          = each.value.rg
  virtual_network_name         = each.value.vnet_name
  remote_virtual_network_id    = var.hub_vnet_id
  allow_forwarded_traffic      = true
  use_remote_gateways          = false
  allow_virtual_network_access = true
}
