# domain-controller module — one hardened WS2025 Core DC in its own spoke.
#
# Responsibilities:
#   * Spoke VNet + identity subnet (private only, no public IP on the DC).
#   * Strict NSG: only AD replication / DCOM / RPC to the peer DC, WinRM from
#     the PAW plane, and the deny-all that Azure applies implicitly after.
#   * Route table forcing all egress (incl. peer-DC traffic) through the
#     Azure Firewall private IP for deep packet inspection.
#   * System-assigned managed identity granted Key Vault Secrets User (RBAC
#     delegation) so the VM reads its own DSRM / admin secrets.
#   * DSRM + local-admin passwords generated and stored in Key Vault.
#   * Custom Script Extension runs hardening + DC promotion (forest or join).
#   * Azure Monitor Agent + DCR association -> Log Analytics -> Sentinel.

variable "name_prefix" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "vnet_address_space" { type = list(string) }
variable "dc_private_ip" { type = string }
variable "peer_dc_private_ip" { type = string }
variable "firewall_private_ip" { type = string }
variable "paw_address_space" { type = list(string) }
variable "vm_size" { type = string }
variable "admin_username" { type = string }
variable "key_vault_id" { type = string }
variable "key_vault_uri" { type = string }
variable "log_analytics_workspace_id" { type = string }
variable "dcr_id" { type = string }
variable "ad_domain_name" { type = string }
variable "ad_netbios_name" { type = string }
variable "dc_role" {
  type = string # "forest_root" | "additional_dc"
  validation {
    condition     = contains(["forest_root", "additional_dc"], var.dc_role)
    error_message = "dc_role must be 'forest_root' or 'additional_dc'."
  }
}
variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  identity_subnet_prefix = cidrsubnet(var.vnet_address_space[0], 1, 0) # first /25
  # AD port sets (kept in sync with the firewall module).
  ad_tcp_ports = ["53", "88", "135", "139", "389", "445", "464", "636", "3268", "3269", "9389", "49152-65535"]
  ad_udp_ports = ["53", "88", "123", "389", "464"]
}

# ---- Network ---------------------------------------------------------------
resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "identity" {
  name                 = "snet-identity"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [local.identity_subnet_prefix]
}

# ---- Forced tunneling: all traffic egresses via the firewall ---------------
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

resource "azurerm_subnet_route_table_association" "identity" {
  subnet_id      = azurerm_subnet.identity.id
  route_table_id = azurerm_route_table.spoke.id
}

# ---- Strict NSG ------------------------------------------------------------
resource "azurerm_network_security_group" "dc" {
  name                = "nsg-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# Inbound: AD replication / DCOM / RPC from the peer DC (TCP).
resource "azurerm_network_security_rule" "in_peer_tcp" {
  name                        = "Allow-PeerDC-AD-TCP-In"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.dc.name
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "${var.peer_dc_private_ip}/32"
  source_port_range           = "*"
  destination_address_prefix  = "${var.dc_private_ip}/32"
  destination_port_ranges     = local.ad_tcp_ports
}

# Inbound: AD replication / Kerberos / DNS / NTP from the peer DC (UDP).
resource "azurerm_network_security_rule" "in_peer_udp" {
  name                        = "Allow-PeerDC-AD-UDP-In"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.dc.name
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_address_prefix       = "${var.peer_dc_private_ip}/32"
  source_port_range           = "*"
  destination_address_prefix  = "${var.dc_private_ip}/32"
  destination_port_ranges     = local.ad_udp_ports
}

# Inbound: WinRM (+ RDP fallback) from the PAW plane only.
resource "azurerm_network_security_rule" "in_paw_winrm" {
  name                        = "Allow-PAW-WinRM-In"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.dc.name
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefixes     = var.paw_address_space
  source_port_range           = "*"
  destination_address_prefix  = "${var.dc_private_ip}/32"
  destination_port_ranges     = ["5985", "5986", "3389"]
}

# Explicit deny-all inbound (defense in depth above Azure's default rules).
resource "azurerm_network_security_rule" "in_deny_all" {
  name                        = "Deny-All-Inbound"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.dc.name
  priority                    = 4000
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_address_prefix       = "*"
  source_port_range           = "*"
  destination_address_prefix  = "*"
  destination_port_range      = "*"
}

# Outbound: AD replication to the peer DC (TCP + UDP) — egress still routes via
# the firewall (UDR) for DPI, but the NSG scopes what may leave at all.
resource "azurerm_network_security_rule" "out_peer_tcp" {
  name                        = "Allow-PeerDC-AD-TCP-Out"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.dc.name
  priority                    = 100
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "${var.dc_private_ip}/32"
  source_port_range           = "*"
  destination_address_prefix  = "${var.peer_dc_private_ip}/32"
  destination_port_ranges     = local.ad_tcp_ports
}

resource "azurerm_network_security_rule" "out_peer_udp" {
  name                        = "Allow-PeerDC-AD-UDP-Out"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.dc.name
  priority                    = 110
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Udp"
  source_address_prefix       = "${var.dc_private_ip}/32"
  source_port_range           = "*"
  destination_address_prefix  = "${var.peer_dc_private_ip}/32"
  destination_port_ranges     = local.ad_udp_ports
}

# Outbound: allow reaching Azure platform services (KV, monitor) via firewall.
resource "azurerm_network_security_rule" "out_azure" {
  name                        = "Allow-Azure-Platform-Out"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.dc.name
  priority                    = 200
  direction                   = "Outbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_address_prefix       = "${var.dc_private_ip}/32"
  source_port_range           = "*"
  destination_address_prefix  = "AzureCloud"
  destination_port_ranges     = ["443"]
}

resource "azurerm_subnet_network_security_group_association" "identity" {
  subnet_id                 = azurerm_subnet.identity.id
  network_security_group_id = azurerm_network_security_group.dc.id
}

# ---- NIC (private only) ----------------------------------------------------
resource "azurerm_network_interface" "dc" {
  name                = "nic-${var.name_prefix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.identity.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.dc_private_ip
    # No public_ip_address_id — DCs are never internet-facing.
  }
}

# ---- Secrets: DSRM + local admin, delegated via Key Vault RBAC -------------
resource "random_password" "local_admin" {
  length      = 28
  special     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
}

resource "random_password" "dsrm" {
  length      = 28
  special     = true
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
}

resource "azurerm_key_vault_secret" "local_admin" {
  name         = "${var.name_prefix}-local-admin"
  value        = random_password.local_admin.result
  key_vault_id = var.key_vault_id
  content_type = "password"
  tags         = var.tags
}

resource "azurerm_key_vault_secret" "dsrm" {
  name         = "${var.name_prefix}-dsrm"
  value        = random_password.dsrm.result
  key_vault_id = var.key_vault_id
  content_type = "password"
  tags         = var.tags
}

# Forest root only: publish the built-in Administrator password (which becomes
# the domain admin after promotion) so the additional DC can join. The
# additional-DC bootstrap reads this 'domain-admin' secret via managed identity.
resource "azurerm_key_vault_secret" "domain_admin" {
  count        = var.dc_role == "forest_root" ? 1 : 0
  name         = "domain-admin"
  value        = random_password.local_admin.result
  key_vault_id = var.key_vault_id
  content_type = "password"
  tags         = var.tags
}

# ---- VM: Windows Server 2025 Datacenter CORE (no GUI) ----------------------
resource "azurerm_windows_virtual_machine" "dc" {
  name                = "vm-${var.name_prefix}"
  computer_name       = upper(replace(var.name_prefix, "-", ""))
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = random_password.local_admin.result
  network_interface_ids = [azurerm_network_interface.dc.id]
  provision_vm_agent  = true
  tags                = var.tags

  # System-assigned managed identity for Key Vault delegation.
  identity {
    type = "SystemAssigned"
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS" # cost-optimized; Premium optional
  }

  # Server 2025 Datacenter Core — Server Core SKU = no Desktop Experience.
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2025-datacenter-core-g2"
    version   = "latest"
  }

  # Disk encryption + secure boot / vTPM (trusted launch).
  secure_boot_enabled = true
  vtpm_enabled        = true

  lifecycle {
    ignore_changes = [admin_password] # rotated post-promotion via Key Vault
  }
}

# Grant the DC's managed identity scoped read on Key Vault secrets (delegation).
resource "azurerm_role_assignment" "dc_kv_reader" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_windows_virtual_machine.dc.identity[0].principal_id
}

# ---- Monitoring: Azure Monitor Agent + DCR association ----------------------
resource "azurerm_virtual_machine_extension" "ama" {
  name                       = "AzureMonitorWindowsAgent"
  virtual_machine_id         = azurerm_windows_virtual_machine.dc.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorWindowsAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

resource "azurerm_monitor_data_collection_rule_association" "dc" {
  name                    = "dcra-${var.name_prefix}"
  target_resource_id      = azurerm_windows_virtual_machine.dc.id
  data_collection_rule_id = var.dcr_id
}

# ---- Hardening + DC promotion via Custom Script Extension ------------------
# The script reads DSRM / admin secrets from Key Vault using the VM's managed
# identity (IMDS token), applies the Server 2025 Core hardening baseline, then
# promotes: forest creation (DC1) or additional-DC join (DC2).
locals {
  bootstrap_command = join(" ", [
    "powershell -ExecutionPolicy Bypass -NoProfile -File Bootstrap-DomainController.ps1",
    "-DomainName ${var.ad_domain_name}",
    "-NetbiosName ${var.ad_netbios_name}",
    "-DcRole ${var.dc_role}",
    "-KeyVaultSecretName ${azurerm_key_vault_secret.dsrm.name}",
    "-KeyVaultUri ${trimsuffix(var.key_vault_uri, "/")}",
  ])
}

resource "azurerm_virtual_machine_extension" "bootstrap" {
  name                       = "dc-bootstrap"
  virtual_machine_id         = azurerm_windows_virtual_machine.dc.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  depends_on                 = [azurerm_role_assignment.dc_kv_reader]

  settings = jsonencode({
    fileUris = [
      # In production, host these in a private storage account / blob with SAS.
      # For the repo they live under modules/domain-controller/scripts/.
    ]
  })

  protected_settings = jsonencode({
    commandToExecute = local.bootstrap_command
  })
}

output "vnet_id" { value = azurerm_virtual_network.spoke.id }
output "vnet_name" { value = azurerm_virtual_network.spoke.name }
output "private_ip" { value = var.dc_private_ip }
output "vm_id" { value = azurerm_windows_virtual_machine.dc.id }
output "principal_id" { value = azurerm_windows_virtual_machine.dc.identity[0].principal_id }
