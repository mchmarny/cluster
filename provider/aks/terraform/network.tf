// =====================================================================================
// Resource Group
// =====================================================================================

resource "azurerm_resource_group" "main" {
  name     = local.resource_group_name
  location = local.region
  tags     = local.tags
}

// =====================================================================================
// Virtual Network
// =====================================================================================

resource "azurerm_virtual_network" "main" {
  name                = "${local.prefix}-vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [local.vnet_cidr]
  tags                = local.tags

  // Hard subscription validation via precondition (matches EKS/GKE base network resource).
  lifecycle {
    precondition {
      condition     = data.azurerm_client_config.current.subscription_id == local.subscription
      error_message = "Invalid Azure subscription (want: ${local.subscription}, got: ${data.azurerm_client_config.current.subscription_id})."
    }
  }
}

// =====================================================================================
// Subnets
// =====================================================================================

resource "azurerm_subnet" "system" {
  name                 = "${local.prefix}-system-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.system_subnet_cidr]
}

resource "azurerm_subnet" "worker" {
  name                 = "${local.prefix}-worker-subnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.worker_subnet_cidr]
}

// =====================================================================================
// Network Security Groups (folded here, GKE-style — no separate secgroup.tf)
// =====================================================================================

// Baseline NSG: allow intra-VNet traffic, deny inbound internet by default.
// AKS manages the fine-grained rules required by kubelet/LB; this provides a
// private-by-default posture on the node subnets.
resource "azurerm_network_security_group" "nodes" {
  name                = "${local.prefix}-nodes-nsg"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  security_rule {
    name                       = "allow-vnet-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "allow-lb-inbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "system" {
  subnet_id                 = azurerm_subnet.system.id
  network_security_group_id = azurerm_network_security_group.nodes.id
}

resource "azurerm_subnet_network_security_group_association" "worker" {
  subnet_id                 = azurerm_subnet.worker.id
  network_security_group_id = azurerm_network_security_group.nodes.id
}

// =====================================================================================
// NAT Gateway (deterministic egress for private nodes)
// =====================================================================================

resource "azurerm_public_ip" "nat" {
  count = local.nat_enabled ? 1 : 0

  name                = "${local.prefix}-nat-pip"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = local.tags
}

resource "azurerm_nat_gateway" "main" {
  count = local.nat_enabled ? 1 : 0

  name                    = "${local.prefix}-nat"
  location                = azurerm_resource_group.main.location
  resource_group_name     = azurerm_resource_group.main.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 4
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  count = local.nat_enabled ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.main[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "system" {
  count = local.nat_enabled ? 1 : 0

  subnet_id      = azurerm_subnet.system.id
  nat_gateway_id = azurerm_nat_gateway.main[0].id
}

resource "azurerm_subnet_nat_gateway_association" "worker" {
  count = local.nat_enabled ? 1 : 0

  subnet_id      = azurerm_subnet.worker.id
  nat_gateway_id = azurerm_nat_gateway.main[0].id
}
