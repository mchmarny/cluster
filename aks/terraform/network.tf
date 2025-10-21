// Virtual Network
resource "azurerm_virtual_network" "main" {
  name                = "${local.cluster_name}-vnet"
  location            = local.location
  resource_group_name = local.resource_group_name
  address_space       = [local.vnet_address_space]
  tags                = local.tags
}

// Subnet for system node pool
resource "azurerm_subnet" "system" {
  name                 = "${local.cluster_name}-system-subnet"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.config.network.systemSubnetCidr]

  # Delegate to AKS
  service_endpoints = [
    "Microsoft.Storage",
    "Microsoft.Sql",
    "Microsoft.KeyVault"
  ]
}

// Subnet for worker node pools
resource "azurerm_subnet" "worker" {
  name                 = "${local.cluster_name}-worker-subnet"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.config.network.workerSubnetCidr]

  service_endpoints = [
    "Microsoft.Storage",
    "Microsoft.Sql",
    "Microsoft.KeyVault"
  ]
}

// Subnet for pods (when using Azure CNI with pod subnet)
resource "azurerm_subnet" "pods" {
  count = local.network_plugin == "azure" && try(local.config.network.podSubnetCidr, null) != null ? 1 : 0

  name                 = "${local.cluster_name}-pod-subnet"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.config.network.podSubnetCidr]

  delegation {
    name = "aks-delegation"
    service_delegation {
      name    = "Microsoft.ContainerService/managedClusters"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

// Optional Application Gateway subnet
resource "azurerm_subnet" "appgw" {
  count = try(local.config.network.appGatewaySubnetCidr, null) != null ? 1 : 0

  name                 = "${local.cluster_name}-appgw-subnet"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [local.config.network.appGatewaySubnetCidr]
}

// Network Security Group for system node pool
resource "azurerm_network_security_group" "system" {
  name                = "${local.cluster_name}-system-nsg"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = local.tags
}

// System NSG - Allow SSH from authorized ranges
resource "azurerm_network_security_rule" "system_ssh" {
  name                        = "AllowSSH"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = local.api_server_authorized_ranges
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.system.name
}

// System NSG - Allow node-to-node communication
resource "azurerm_network_security_rule" "system_node_to_node" {
  name                        = "AllowNodeToNode"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = local.vnet_address_space
  destination_address_prefix  = local.vnet_address_space
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.system.name
}

// System NSG - Allow kubelet
resource "azurerm_network_security_rule" "system_kubelet" {
  name                        = "AllowKubelet"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "10250"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.system.name
}

// System NSG - ICMP for path MTU discovery
resource "azurerm_network_security_rule" "system_icmp" {
  name                        = "AllowICMP"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Icmp"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.system.name
}

// System NSG - Deny all other inbound
resource "azurerm_network_security_rule" "system_deny_inbound" {
  name                        = "DenyAllInbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.system.name
}

// Network Security Group for worker node pools
resource "azurerm_network_security_group" "worker" {
  name                = "${local.cluster_name}-worker-nsg"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = local.tags
}

// Worker NSG - Allow SSH from authorized ranges
resource "azurerm_network_security_rule" "worker_ssh" {
  name                        = "AllowSSH"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = local.api_server_authorized_ranges
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.worker.name
}

// Worker NSG - Allow node-to-node communication
resource "azurerm_network_security_rule" "worker_node_to_node" {
  name                        = "AllowNodeToNode"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = local.vnet_address_space
  destination_address_prefix  = local.vnet_address_space
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.worker.name
}

// Worker NSG - Allow kubelet
resource "azurerm_network_security_rule" "worker_kubelet" {
  name                        = "AllowKubelet"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "10250"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.worker.name
}

// Worker NSG - Allow ingress from load balancers
resource "azurerm_network_security_rule" "worker_ingress" {
  name                        = "AllowLoadBalancer"
  priority                    = 130
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "AzureLoadBalancer"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.worker.name
}

// Worker NSG - ICMP for path MTU discovery
resource "azurerm_network_security_rule" "worker_icmp" {
  name                        = "AllowICMP"
  priority                    = 140
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Icmp"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.worker.name
}

// Worker NSG - Deny all other inbound
resource "azurerm_network_security_rule" "worker_deny_inbound" {
  name                        = "DenyAllInbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.worker.name
}

// Optional Network Security Group for pods
resource "azurerm_network_security_group" "pods" {
  count = local.network_plugin == "azure" && try(local.config.network.podSubnetCidr, null) != null ? 1 : 0

  name                = "${local.cluster_name}-pod-nsg"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = local.tags
}

// Pod NSG - Allow pod-to-pod communication
resource "azurerm_network_security_rule" "pod_to_pod" {
  count = local.network_plugin == "azure" && try(local.config.network.podSubnetCidr, null) != null ? 1 : 0

  name                        = "AllowPodToPod"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = local.pod_cidr
  destination_address_prefix  = local.pod_cidr
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.pods[0].name
}

// Pod NSG - Allow access from nodes
resource "azurerm_network_security_rule" "pod_from_nodes" {
  count = local.network_plugin == "azure" && try(local.config.network.podSubnetCidr, null) != null ? 1 : 0

  name                        = "AllowFromNodes"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = local.vnet_address_space
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.pods[0].name
}

// Pod NSG - ICMP for path MTU discovery
resource "azurerm_network_security_rule" "pod_icmp" {
  count = local.network_plugin == "azure" && try(local.config.network.podSubnetCidr, null) != null ? 1 : 0

  name                        = "AllowICMP"
  priority                    = 120
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Icmp"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = azurerm_network_security_group.pods[0].name
}

// Associate NSGs with subnets
resource "azurerm_subnet_network_security_group_association" "system" {
  subnet_id                 = azurerm_subnet.system.id
  network_security_group_id = azurerm_network_security_group.system.id
}

resource "azurerm_subnet_network_security_group_association" "worker" {
  subnet_id                 = azurerm_subnet.worker.id
  network_security_group_id = azurerm_network_security_group.worker.id
}

resource "azurerm_subnet_network_security_group_association" "pods" {
  count = local.network_plugin == "azure" && try(local.config.network.podSubnetCidr, null) != null ? 1 : 0

  subnet_id                 = azurerm_subnet.pods[0].id
  network_security_group_id = azurerm_network_security_group.pods[0].id
}

// Route table for controlling egress traffic
resource "azurerm_route_table" "main" {
  count = local.outbound_type == "userDefinedRouting" ? 1 : 0

  name                = "${local.cluster_name}-rt"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = local.tags
}

// Default route to firewall/NAT (example - customize based on your setup)
resource "azurerm_route" "default" {
  count = local.outbound_type == "userDefinedRouting" ? 1 : 0

  name                   = "default-route"
  resource_group_name    = local.resource_group_name
  route_table_name       = azurerm_route_table.main[0].name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = try(local.config.network.firewallPrivateIp, null)
}

// Associate route table with system subnet
resource "azurerm_subnet_route_table_association" "system" {
  count = local.outbound_type == "userDefinedRouting" ? 1 : 0

  subnet_id      = azurerm_subnet.system.id
  route_table_id = azurerm_route_table.main[0].id
}

// Associate route table with worker subnet
resource "azurerm_subnet_route_table_association" "worker" {
  count = local.outbound_type == "userDefinedRouting" ? 1 : 0

  subnet_id      = azurerm_subnet.worker.id
  route_table_id = azurerm_route_table.main[0].id
}

// Optional NAT Gateway for outbound connectivity
resource "azurerm_public_ip" "nat" {
  count = local.outbound_type == "natGateway" ? 1 : 0

  name                = "${local.cluster_name}-nat-pip"
  location            = local.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = local.tags
}

resource "azurerm_nat_gateway" "main" {
  count = local.outbound_type == "natGateway" ? 1 : 0

  name                    = "${local.cluster_name}-nat"
  location                = local.location
  resource_group_name     = local.resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  zones                   = ["1", "2", "3"]
  tags                    = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "main" {
  count = local.outbound_type == "natGateway" ? 1 : 0

  nat_gateway_id       = azurerm_nat_gateway.main[0].id
  public_ip_address_id = azurerm_public_ip.nat[0].id
}

resource "azurerm_subnet_nat_gateway_association" "system" {
  count = local.outbound_type == "natGateway" ? 1 : 0

  subnet_id      = azurerm_subnet.system.id
  nat_gateway_id = azurerm_nat_gateway.main[0].id
}

resource "azurerm_subnet_nat_gateway_association" "worker" {
  count = local.outbound_type == "natGateway" ? 1 : 0

  subnet_id      = azurerm_subnet.worker.id
  nat_gateway_id = azurerm_nat_gateway.main[0].id
}
