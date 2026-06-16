# locals.tf — naming convention + derived values (CAF-aligned)

locals {
  # CAF-style naming: <type>-<workload>-<env>-<region-abbr>
  loc_abbr = {
    centralus     = "cus"
    canadacentral = "cnc"
  }

  p   = var.org_prefix
  env = var.environment
  r1  = local.loc_abbr[var.primary_location]
  r2  = local.loc_abbr[var.secondary_location]

  # Resource group names by Well-Architected landing-zone function.
  rg = {
    connectivity = "rg-${local.p}-connectivity-${local.env}-${local.r1}"
    identity_dc1 = "rg-${local.p}-identity-${local.env}-${local.r1}"
    identity_dc2 = "rg-${local.p}-identity-${local.env}-${local.r2}"
    management   = "rg-${local.p}-management-${local.env}-${local.r1}"
    security     = "rg-${local.p}-security-${local.env}-${local.r1}"
  }

  common_tags = merge(var.tags, {
    environment = var.environment
    deployed_at = "terraform"
  })
}
