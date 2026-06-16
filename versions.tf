# versions.tf — Terraform + provider version pinning
# Pinned to known-good majors to keep deployments reproducible.

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.10"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
  }

  # Remote state. Pre-create the storage account / container out-of-band
  # (see docs/deployment.md) or comment this block out for a local-state PoC.
  backend "azurerm" {
    # resource_group_name  = "rg-tfstate-mgmt"
    # storage_account_name = "sttfstatehomelab"
    # container_name       = "tfstate"
    # key                  = "ad-landing-zone.tfstate"
  }
}
