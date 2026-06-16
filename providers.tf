# providers.tf — provider configuration

provider "azurerm" {
  features {
    key_vault {
      # Soft-delete + purge protection are enforced; never auto-purge in prod.
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      # Guard rail: refuse to delete an RG that still has resources in it.
      prevent_deletion_if_contains_resources = true
    }
    virtual_machine {
      delete_os_disk_on_deletion = true
    }
  }

  # Authenticate via `az login`, a service principal, or a managed identity.
  # subscription_id is supplied via TF_VAR / env to avoid hardcoding.
  subscription_id = var.subscription_id
}

provider "azuread" {
  # Uses the same identity context as azurerm for Key Vault / RBAC delegation.
}

provider "random" {}
