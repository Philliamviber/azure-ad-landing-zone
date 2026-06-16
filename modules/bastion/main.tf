# bastion module — Azure Bastion as the only interactive entry point.
#
# Standard SKU is used so native client / IP-based connection and tunneling are
# available for reaching the PAW. No public IPs ever land on the DCs or PAW;
# operators connect to Bastion, then RDP/SSH to the PAW, then WinRM to the DCs.

variable "name" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "bastion_subnet_id" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_public_ip" "bastion" {
  name                = "pip-${var.name}"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_bastion_host" "this" {
  name                = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  tunneling_enabled   = true # enables native-client tunneling to the PAW
  tags                = var.tags

  ip_configuration {
    name                 = "bastion-ipconfig"
    subnet_id            = var.bastion_subnet_id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
}

output "bastion_id" { value = azurerm_bastion_host.this.id }
