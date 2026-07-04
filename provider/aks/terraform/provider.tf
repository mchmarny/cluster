provider "azurerm" {
  features {}

  // Target subscription is derived from deployment.tenancy (see main.tf locals).
  subscription_id = local.subscription
}
