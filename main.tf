# main.tf — root composition that wires the landing-zone modules together.
#
# Deployment order (Terraform resolves via dependencies):
#   1. Resource groups (WAF-aligned)
#   2. Management plane: Log Analytics + Sentinel
#   3. Security plane: Key Vault (RBAC delegation)
#   4. Connectivity hub: VNet, Azure Firewall (Premium/IDPS), Bastion
#   5. Identity spokes: DC1 (Central US), DC2 (Canada Central)
#   6. Privileged plane: PAW VNet + jump host
#   7. Peerings + UDRs force all spoke-to-spoke AD traffic through the firewall.

# ---------------------------------------------------------------------------
# 1. Resource groups
# ---------------------------------------------------------------------------
module "resource_groups" {
  source = "./modules/resource-groups"

  resource_groups = {
    connectivity = { name = local.rg.connectivity, location = var.primary_location }
    identity_dc1 = { name = local.rg.identity_dc1, location = var.primary_location }
    identity_dc2 = { name = local.rg.identity_dc2, location = var.secondary_location }
    management   = { name = local.rg.management, location = var.primary_location }
    security     = { name = local.rg.security, location = var.primary_location }
  }
  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# 2. Management plane — Log Analytics + Sentinel
# ---------------------------------------------------------------------------
module "log_analytics" {
  source = "./modules/log-analytics"

  name                = "log-${local.p}-${local.env}-${local.r1}"
  resource_group_name = module.resource_groups.names["management"]
  location            = var.primary_location
  retention_in_days   = var.log_retention_days
  tags                = local.common_tags
}

module "sentinel" {
  source = "./modules/sentinel"

  log_analytics_workspace_id = module.log_analytics.workspace_id
  workspace_name             = module.log_analytics.workspace_name
  resource_group_name        = module.resource_groups.names["management"]
  location                   = var.primary_location
  tags                       = local.common_tags
}

# ---------------------------------------------------------------------------
# 3. Security plane — Key Vault with RBAC delegation
# ---------------------------------------------------------------------------
module "key_vault" {
  source = "./modules/key-vault"

  name                       = "kv-${local.p}-${local.env}-${local.r1}"
  resource_group_name        = module.resource_groups.names["security"]
  location                   = var.primary_location
  tenant_id                  = var.tenant_id
  log_analytics_workspace_id = module.log_analytics.workspace_id
  # No public access — reached over the management/private plane only.
  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# 4. Connectivity hub — VNet + Azure Firewall Premium + Bastion
# ---------------------------------------------------------------------------
module "hub" {
  source = "./modules/networking-hub"

  name_prefix                = "${local.p}-hub-${local.env}-${local.r1}"
  resource_group_name        = module.resource_groups.names["connectivity"]
  location                   = var.primary_location
  address_space              = var.hub_address_space
  log_analytics_workspace_id = module.log_analytics.workspace_id
  tags                       = local.common_tags
}

module "firewall" {
  source = "./modules/azure-firewall"

  name                       = "afw-${local.p}-${local.env}-${local.r1}"
  resource_group_name        = module.resource_groups.names["connectivity"]
  location                   = var.primary_location
  sku_tier                   = var.firewall_sku_tier
  firewall_subnet_id         = module.hub.firewall_subnet_id
  log_analytics_workspace_id = module.log_analytics.workspace_id

  # Spoke address spaces the firewall mediates between (DPI/IDPS applied).
  dc1_address_space = var.spoke_dc1_address_space
  dc2_address_space = var.spoke_dc2_address_space
  paw_address_space = var.privileged_address_space
  tags              = local.common_tags
}

module "bastion" {
  source = "./modules/bastion"

  name                = "bas-${local.p}-${local.env}-${local.r1}"
  resource_group_name = module.resource_groups.names["connectivity"]
  location            = var.primary_location
  bastion_subnet_id   = module.hub.bastion_subnet_id
  tags                = local.common_tags
}

# ---------------------------------------------------------------------------
# 5. Identity spokes — domain controllers
# ---------------------------------------------------------------------------
# DC1 — forest root (Central US). Creates the homelab.local forest.
module "dc1" {
  source = "./modules/domain-controller"

  name_prefix                = "${local.p}-dc1"
  resource_group_name        = module.resource_groups.names["identity_dc1"]
  location                   = var.primary_location
  vnet_address_space         = var.spoke_dc1_address_space
  dc_private_ip              = cidrhost(var.spoke_dc1_address_space[0], 4) # 10.20.0.4
  peer_dc_private_ip         = cidrhost(var.spoke_dc2_address_space[0], 4) # 10.21.0.4
  firewall_private_ip        = module.firewall.private_ip
  paw_address_space          = var.privileged_address_space
  vm_size                    = var.dc_vm_size
  admin_username             = var.admin_username
  key_vault_id               = module.key_vault.id
  key_vault_uri              = module.key_vault.uri
  log_analytics_workspace_id = module.log_analytics.workspace_id
  dcr_id                     = module.log_analytics.windows_dcr_id

  ad_domain_name  = var.ad_domain_name
  ad_netbios_name = var.ad_netbios_name
  dc_role         = "forest_root" # promotes first, creates the forest
  tags            = local.common_tags
}

# DC2 — additional DC (Canada Central). Joins the existing forest.
module "dc2" {
  source = "./modules/domain-controller"

  name_prefix                = "${local.p}-dc2"
  resource_group_name        = module.resource_groups.names["identity_dc2"]
  location                   = var.secondary_location
  vnet_address_space         = var.spoke_dc2_address_space
  dc_private_ip              = cidrhost(var.spoke_dc2_address_space[0], 4) # 10.21.0.4
  peer_dc_private_ip         = cidrhost(var.spoke_dc1_address_space[0], 4) # 10.20.0.4
  firewall_private_ip        = module.firewall.private_ip
  paw_address_space          = var.privileged_address_space
  vm_size                    = var.dc_vm_size
  admin_username             = var.admin_username
  key_vault_id               = module.key_vault.id
  key_vault_uri              = module.key_vault.uri
  log_analytics_workspace_id = module.log_analytics.workspace_id
  dcr_id                     = module.log_analytics.windows_dcr_id

  ad_domain_name  = var.ad_domain_name
  ad_netbios_name = var.ad_netbios_name
  dc_role         = "additional_dc" # joins forest created by DC1
  depends_on      = [module.dc1]
  tags            = local.common_tags
}

# ---------------------------------------------------------------------------
# 6. Privileged plane — PAW VNet + jump host
# ---------------------------------------------------------------------------
module "paw_spoke" {
  source = "./modules/networking-spoke"

  name_prefix         = "${local.p}-paw-${local.env}-${local.r1}"
  resource_group_name = module.resource_groups.names["security"]
  location            = var.primary_location
  address_space       = var.privileged_address_space
  subnet_prefix       = cidrsubnet(var.privileged_address_space[0], 1, 0) # 10.30.0.0/25
  firewall_private_ip = module.firewall.private_ip
  # PAW NSG: outbound WinRM to DCs only; inbound from Bastion only.
  spoke_type                 = "privileged"
  dc_address_spaces          = concat(var.spoke_dc1_address_space, var.spoke_dc2_address_space)
  bastion_address_space      = module.hub.bastion_subnet_prefix
  log_analytics_workspace_id = module.log_analytics.workspace_id

  # PAW jump host
  paw_vm_size    = var.paw_vm_size
  admin_username = var.admin_username
  key_vault_id   = module.key_vault.id
  tags           = local.common_tags
}

# ---------------------------------------------------------------------------
# 7. Hub <-> spoke peerings (AD replication traverses the firewall via UDR)
# ---------------------------------------------------------------------------
module "peerings" {
  source = "./modules/networking-hub/peering"

  hub_vnet_id   = module.hub.vnet_id
  hub_vnet_name = module.hub.vnet_name
  hub_rg_name   = module.resource_groups.names["connectivity"]

  spokes = {
    dc1 = { vnet_id = module.dc1.vnet_id, vnet_name = module.dc1.vnet_name, rg = module.resource_groups.names["identity_dc1"] }
    dc2 = { vnet_id = module.dc2.vnet_id, vnet_name = module.dc2.vnet_name, rg = module.resource_groups.names["identity_dc2"] }
    paw = { vnet_id = module.paw_spoke.vnet_id, vnet_name = module.paw_spoke.vnet_name, rg = module.resource_groups.names["security"] }
  }
}
