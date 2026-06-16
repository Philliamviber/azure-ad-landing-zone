# outputs.tf — operator-facing outputs after apply.

output "resource_groups" {
  description = "Deployed resource group names by CAF function."
  value       = module.resource_groups.names
}

output "domain_fqdn" {
  description = "Active Directory forest FQDN."
  value       = var.ad_domain_name
}

output "dc1_private_ip" {
  description = "Private IP of DC1 (forest root, Central US)."
  value       = module.dc1.private_ip
}

output "dc2_private_ip" {
  description = "Private IP of DC2 (additional DC, Canada Central)."
  value       = module.dc2.private_ip
}

output "firewall_private_ip" {
  description = "Azure Firewall private IP (UDR next hop)."
  value       = module.firewall.private_ip
}

output "key_vault_uri" {
  description = "Key Vault URI holding DSRM / admin secrets."
  value       = module.key_vault.uri
}

output "sentinel_workspace_id" {
  description = "Log Analytics workspace onboarded to Microsoft Sentinel."
  value       = module.sentinel.sentinel_workspace_id
}

output "paw_private_ip" {
  description = "Private IP of the PAW jump host (reach via Azure Bastion)."
  value       = module.paw_spoke.paw_private_ip
}

output "connect_hint" {
  description = "How operators reach the environment."
  value       = "Azure Bastion -> PAW (${module.paw_spoke.paw_private_ip}) -> WinRM to DC1/DC2. No DC is internet-facing."
}
