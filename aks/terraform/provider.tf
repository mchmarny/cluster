provider "azurerm" {
  subscription_id = local.subscription_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = local.deletion_protection
    }

    key_vault {
      purge_soft_delete_on_destroy    = !local.deletion_protection
      recover_soft_deleted_key_vaults = local.deletion_protection
    }
  }
}

provider "azuread" {
}
