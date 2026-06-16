# networking-spoke module — generic spoke VNet, used here for the PRIVILEGED
# PLANE (PAW). Builds the VNet/subnet, a tightly-scoped NSG, a forced-tunnel
# UDR through the firewall, and (for spoke_type = "privileged") the PAW jump
# host that operators land on via Azure Bastion and use to WinRM into the DCs.

variable "name_prefix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "address_space" { type = list(string) }
variable "subnet_prefix" { type = string }
variable "firewall_private_ip" { type = string }
variable "spoke_type" {
  type    = string # "privileged" builds a PAW VM; anything else = network only
  default = "generic"
}
variable "dc_address_spaces" {
  type    = list(string)
  default = []
}
variable "bastion_address_space" {
  type    = string
  default = ""
}
variable "log_analytics_workspace_id" { type = string }

# PAW VM inputs (only consumed when spoke_type = "privileged").
variable "paw_vm_size" {
  type    = string
  default = "Standard_B2s"
}
variable "admin_username" {
  type    = string
  default = "pawadmin"
}
variable "key_vault_id" {
  type    = string
  default = ""
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  is_paw = var.spoke_type == "privileged"
}

resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.address_space
  tags                = var.tags
}

resource "azurerm_subnet" "main" {
  name                 = "snet-paw"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [var.subnet_prefix]
}

# Forced tunnel via firewall.
resource "azurerm_route_table" "spoke" {
  name                = "rt-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  route {
    name                   = "default-via-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.firewall_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "main" {
  subnet_id      = azurerm_subnet.main.id
  route_table_id = azurerm_route_table.spoke.id
}

# ---- PAW NSG: inbound from Bastion only, outbound WinRM to DCs only ---------
resource "azurerm_network_security_group" "paw" {
  name                = "nsg-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_network_security_rule" "in_bastion" {
  count                       = local.is_paw ? 1 : 0
  name                        = "Allow-Bastion-RDP-In"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.paw.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = var.bastion_address_space
  source_port_range           = "*"
  destination_address_prefix  = var.subnet_prefix
  destination_port_ranges     = ["3389", "22"]
}

resource "azurerm_network_security_rule" "in_deny_all" {
  name                        = "Deny-All-Inbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.paw.name
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_address_prefix       = "*"
  source_port_range           = "*"
  destination_address_prefix  = "*"
  destination_port_range      = "*"
}

resource "azurerm_network_security_rule" "out_winrm_dcs" {
  count                       = local.is_paw ? 1 : 0
  name                        = "Allow-WinRM-To-DCs-Out"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.paw.name
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = var.subnet_prefix
  source_port_range           = "*"
  destination_address_prefixes = var.dc_address_spaces
  destination_port_ranges     = ["5985", "5986", "3389"]
}

resource "azurerm_network_security_rule" "out_azure" {
  count                       = local.is_paw ? 1 : 0
  name                        = "Allow-Azure-Platform-Out"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.paw.name
  priority                    = 200
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = var.subnet_prefix
  source_port_range           = "*"
  destination_address_prefix  = "AzureCloud"
  destination_port_ranges     = ["443"]
}

resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = azurerm_subnet.main.id
  network_security_group_id = azurerm_network_security_group.paw.id
}

# ---- PAW jump host ---------------------------------------------------------
resource "random_password" "paw_admin" {
  count   = local.is_paw ? 1 : 0
  length  = 28
  special = true
}

resource "azurerm_key_vault_secret" "paw_admin" {
  count        = local.is_paw && var.key_vault_id != "" ? 1 : 0
  name         = "${var.name_prefix}-local-admin"
  value        = random_password.paw_admin[0].result
  key_vault_id = var.key_vault_id
  content_type = "password"
  tags         = var.tags
}

resource "azurerm_network_interface" "paw" {
  count               = local.is_paw ? 1 : 0
  name                = "nic-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    # No public IP — reached only through Azure Bastion.
  }
}

resource "azurerm_windows_virtual_machine" "paw" {
  count               = local.is_paw ? 1 : 0
  name                = "vm-${var.name_prefix}"
  computer_name       = "PAW01"
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = var.paw_vm_size
  admin_username      = var.admin_username
  admin_password      = random_password.paw_admin[0].result
  network_interface_ids = [azurerm_network_interface.paw[0].id]
  provision_vm_agent  = true
  tags                = var.tags

  identity { type = "SystemAssigned" }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  # Server 2025 Core — PAW is also GUI-less; admin via RSAT/PowerShell remoting.
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2025-datacenter-core-g2"
    version   = "latest"
  }

  secure_boot_enabled = true
  vtpm_enabled        = true

  lifecycle { ignore_changes = [admin_password] }
}

output "vnet_id" { value = azurerm_virtual_network.spoke.id }
output "vnet_name" { value = azurerm_virtual_network.spoke.name }
output "paw_private_ip" { value = local.is_paw ? azurerm_network_interface.paw[0].private_ip_address : null }
