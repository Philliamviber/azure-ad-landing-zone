# resource-groups module — WAF/CAF-aligned landing-zone resource groups.

variable "resource_groups" {
  description = "Map of logical name => { name, location } for each RG."
  type = map(object({
    name     = string
    location = string
  }))
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_resource_group" "this" {
  for_each = var.resource_groups

  name     = each.value.name
  location = each.value.location
  tags     = merge(var.tags, { caf_function = each.key })
}

output "names" {
  description = "Logical key => RG name."
  value       = { for k, rg in azurerm_resource_group.this : k => rg.name }
}

output "ids" {
  value = { for k, rg in azurerm_resource_group.this : k => rg.id }
}
