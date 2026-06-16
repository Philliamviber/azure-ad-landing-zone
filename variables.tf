# variables.tf — root input variables
# Defaults are tuned for a cost-optimized, minimal-footprint homelab build.

variable "subscription_id" {
  description = "Target Azure subscription ID."
  type        = string
}

variable "tenant_id" {
  description = "Azure AD (Entra ID) tenant ID hosting the deployment."
  type        = string
}

variable "org_prefix" {
  description = "Short org/workload prefix used in resource names (lowercase, 2-6 chars)."
  type        = string
  default     = "hlab"

  validation {
    condition     = can(regex("^[a-z0-9]{2,6}$", var.org_prefix))
    error_message = "org_prefix must be 2-6 lowercase alphanumeric characters."
  }
}

variable "environment" {
  description = "Environment short name (prod, dev, lab)."
  type        = string
  default     = "prod"
}

variable "primary_location" {
  description = "Primary Azure region (hub + DC1)."
  type        = string
  default     = "centralus"
}

variable "secondary_location" {
  description = "Secondary Azure region (DC2)."
  type        = string
  default     = "canadacentral"
}

variable "ad_domain_name" {
  description = "Active Directory forest root domain FQDN."
  type        = string
  default     = "homelab.local"
}

variable "ad_netbios_name" {
  description = "AD NetBIOS domain name."
  type        = string
  default     = "HOMELAB"
}

# ---- Address space plan (RFC1918, non-overlapping) -------------------------
# Hub:              10.10.0.0/22   (connectivity)
# Spoke - DC1:      10.20.0.0/24   (identity, Central US)
# Spoke - DC2:      10.21.0.0/24   (identity, Canada Central)
# Privileged plane: 10.30.0.0/24   (PAW / management)

variable "hub_address_space" {
  type    = list(string)
  default = ["10.10.0.0/22"]
}

variable "spoke_dc1_address_space" {
  type    = list(string)
  default = ["10.20.0.0/24"]
}

variable "spoke_dc2_address_space" {
  type    = list(string)
  default = ["10.21.0.0/24"]
}

variable "privileged_address_space" {
  type    = list(string)
  default = ["10.30.0.0/24"]
}

# ---- Cost / sizing knobs ----------------------------------------------------
variable "dc_vm_size" {
  description = "VM size for domain controllers. B-series = burstable/cost-optimized."
  type        = string
  default     = "Standard_B2ms" # 2 vCPU / 8 GiB — adequate for a lab DC
}

variable "paw_vm_size" {
  description = "VM size for the PAW jump host."
  type        = string
  default     = "Standard_B2s"
}

variable "firewall_sku_tier" {
  description = "Azure Firewall tier. Premium is required for IDPS / TLS deep packet inspection."
  type        = string
  default     = "Premium"
}

variable "log_retention_days" {
  description = "Log Analytics / Sentinel retention in days."
  type        = number
  default     = 90
}

variable "admin_username" {
  description = "Local admin username injected at VM build (rotated post-promotion)."
  type        = string
  default     = "lzadmin"
}

variable "allowed_paw_source_cidrs" {
  description = "CIDRs permitted to reach Azure Bastion (operator egress IPs)."
  type        = list(string)
  default     = ["0.0.0.0/0"] # TIGHTEN before prod — restrict to operator IPs.
}

variable "tags" {
  description = "Base tags applied to every resource."
  type        = map(string)
  default = {
    workload   = "ad-landing-zone"
    managed_by = "terraform"
    framework  = "azure-waf"
  }
}
