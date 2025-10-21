# VCN (Virtual Cloud Network)
resource "oci_core_vcn" "main" {
  compartment_id = local.compartment_ocid
  display_name   = "${local.prefix}-vcn"
  cidr_blocks    = [local.vcn_cidr]
  dns_label      = replace(local.prefix, "-", "")

  freeform_tags = local.freeform_tags
}

# Internet Gateway
resource "oci_core_internet_gateway" "main" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-igw"
  enabled        = true

  freeform_tags = local.freeform_tags
}

# NAT Gateway
resource "oci_core_nat_gateway" "main" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-nat"

  freeform_tags = local.freeform_tags
}

# Service Gateway
data "oci_core_services" "all" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

resource "oci_core_service_gateway" "main" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-sg"

  services {
    service_id = data.oci_core_services.all.services[0].id
  }

  freeform_tags = local.freeform_tags
}

# Public Subnet for Load Balancers
resource "oci_core_subnet" "public" {
  for_each = { for idx, subnet in local.config.network.subnets.public : idx => subnet }

  compartment_id             = local.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = each.value.cidr
  display_name               = "${local.prefix}-public-${each.key}"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  dns_label                  = "pub${each.key}"

  availability_domain = null # Regional subnet

  freeform_tags = local.freeform_tags
}

# API Endpoint Subnet (Private)
resource "oci_core_subnet" "api_endpoint" {
  for_each = { for idx, subnet in local.config.network.subnets.apiEndpoint : idx => subnet }

  compartment_id             = local.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = each.value.cidr
  display_name               = "${local.prefix}-api-${each.key}"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.api_endpoint.id]
  dns_label                  = "api${each.key}"

  availability_domain = null # Regional subnet

  freeform_tags = local.freeform_tags
}

# Node Pool Subnets (Private)
resource "oci_core_subnet" "node_pools" {
  for_each = { for idx, subnet in local.config.network.subnets.nodePools : idx => subnet }

  compartment_id             = local.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = each.value.cidr
  display_name               = "${local.prefix}-nodes-${each.key}"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.node_pools.id]
  dns_label                  = "node${each.key}"

  availability_domain = null # Regional subnet

  freeform_tags = local.freeform_tags
}

# Pod Subnet (Private)
resource "oci_core_subnet" "pods" {
  for_each = { for idx, subnet in local.config.network.subnets.pods : idx => subnet }

  compartment_id             = local.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = each.value.cidr
  display_name               = "${local.prefix}-pods-${each.key}"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.pods.id]
  dns_label                  = "pod${each.key}"

  availability_domain = null # Regional subnet

  freeform_tags = local.freeform_tags
}

# Storage Subnet (Private) for File Storage Service (FSS)
resource "oci_core_subnet" "storage" {
  count = try(length(local.config.network.subnets.storage), 0) > 0 ? length(local.config.network.subnets.storage) : 0

  compartment_id             = local.compartment_ocid
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = local.config.network.subnets.storage[count.index].cidr
  display_name               = "${local.prefix}-storage-${count.index}"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = try(length(local.config.network.subnets.storage), 0) > 0 ? [oci_core_security_list.storage[0].id] : []
  dns_label                  = "stor${count.index}"

  availability_domain = null # Regional subnet

  freeform_tags = local.freeform_tags
}

# Route Tables
resource "oci_core_route_table" "public" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-public-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.main.id
  }

  freeform_tags = local.freeform_tags
}

resource "oci_core_route_table" "private" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-private-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.main.id
  }

  route_rules {
    destination       = data.oci_core_services.all.services[0].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.main.id
  }

  freeform_tags = local.freeform_tags
}

# Security Lists
resource "oci_core_security_list" "public" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-public-sl"

  # Ingress rules for load balancers
  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"

    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    protocol = "6" # TCP
    source   = "0.0.0.0/0"

    tcp_options {
      min = 443
      max = 443
    }
  }

  # ICMP Path Discovery
  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }

  # Egress rules
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  freeform_tags = local.freeform_tags
}

resource "oci_core_security_list" "api_endpoint" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-api-sl"

  # Ingress from allowed CIDRs to Kubernetes API
  dynamic "ingress_security_rules" {
    for_each = local.allowed_cidrs
    content {
      protocol = "6" # TCP
      source   = ingress_security_rules.value

      tcp_options {
        min = 6443
        max = 6443
      }
    }
  }

  # Ingress from VCN
  ingress_security_rules {
    protocol = "6" # TCP
    source   = local.vcn_cidr

    tcp_options {
      min = 6443
      max = 6443
    }
  }

  ingress_security_rules {
    protocol = "6" # TCP
    source   = local.vcn_cidr

    tcp_options {
      min = 12250
      max = 12250
    }
  }

  # ICMP Path Discovery
  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }

  # Egress rules
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  freeform_tags = local.freeform_tags
}

resource "oci_core_security_list" "node_pools" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-nodes-sl"

  # Ingress from within VCN
  ingress_security_rules {
    protocol = "all"
    source   = local.vcn_cidr
  }

  # Ingress from pod CIDR
  ingress_security_rules {
    protocol = "all"
    source   = local.pod_cidr
  }

  # ICMP Path Discovery
  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }

  # Egress rules
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  freeform_tags = local.freeform_tags
}

resource "oci_core_security_list" "pods" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-pods-sl"

  # Ingress from pod CIDR
  ingress_security_rules {
    protocol = "all"
    source   = local.pod_cidr
  }

  # Ingress from node CIDR
  ingress_security_rules {
    protocol = "all"
    source   = local.vcn_cidr
  }

  # ICMP Path Discovery
  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }

  # Egress rules
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  freeform_tags = local.freeform_tags
}

# Security List for Storage Subnet
resource "oci_core_security_list" "storage" {
  count = try(length(local.config.network.subnets.storage), 0) > 0 ? 1 : 0

  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-storage-sl"

  # Ingress NFS RPC (TCP 111)
  ingress_security_rules {
    protocol = "6" # TCP
    source   = local.vcn_cidr

    tcp_options {
      min = 111
      max = 111
    }
  }

  # Ingress NFS RPC (UDP 111)
  ingress_security_rules {
    protocol = "17" # UDP
    source   = local.vcn_cidr

    udp_options {
      min = 111
      max = 111
    }
  }

  # Ingress NFS data (TCP 2048-2050)
  ingress_security_rules {
    protocol = "6" # TCP
    source   = local.vcn_cidr

    tcp_options {
      min = 2048
      max = 2050
    }
  }

  # Ingress NFS data (UDP 2048-2050)
  ingress_security_rules {
    protocol = "17" # UDP
    source   = local.vcn_cidr

    udp_options {
      min = 2048
      max = 2050
    }
  }

  # ICMP Path Discovery
  ingress_security_rules {
    protocol = "1" # ICMP
    source   = "0.0.0.0/0"

    icmp_options {
      type = 3
      code = 4
    }
  }

  # Egress rules
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  freeform_tags = local.freeform_tags
}

# Network Security Groups
resource "oci_core_network_security_group" "control_plane" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-control-plane-nsg"

  freeform_tags = local.freeform_tags
}

resource "oci_core_network_security_group" "load_balancers" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-load-balancers-nsg"

  freeform_tags = local.freeform_tags
}

resource "oci_core_network_security_group" "nodes" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-nodes-nsg"

  freeform_tags = local.freeform_tags
}

resource "oci_core_network_security_group" "pods" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-pods-nsg"

  freeform_tags = local.freeform_tags
}

resource "oci_core_network_security_group" "storage" {
  compartment_id = local.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-storage-nsg"

  freeform_tags = local.freeform_tags
}

# NSG Rules - Control Plane
resource "oci_core_network_security_group_security_rule" "control_plane_ingress_k8s_api" {
  for_each = toset(local.allowed_cidrs)

  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  description               = "Allow Kubernetes API access from authorized CIDRs"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "control_plane_ingress_k8s_api_internal" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = local.vcn_cidr
  source_type               = "CIDR_BLOCK"
  description               = "Allow Kubernetes API access from VCN"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "control_plane_ingress_k8s_webhook" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = local.vcn_cidr
  source_type               = "CIDR_BLOCK"
  description               = "Allow webhook calls from control plane to nodes"

  tcp_options {
    destination_port_range {
      min = 12250
      max = 12250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "control_plane_ingress_icmp" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "1" # ICMP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Allow ICMP Path Discovery"

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "control_plane_egress_all" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow all egress from control plane"
}

# NSG Rules - Load Balancers
resource "oci_core_network_security_group_security_rule" "lb_ingress_http" {
  network_security_group_id = oci_core_network_security_group.load_balancers.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Allow HTTP traffic"

  tcp_options {
    destination_port_range {
      min = 80
      max = 80
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_ingress_https" {
  network_security_group_id = oci_core_network_security_group.load_balancers.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Allow HTTPS traffic"

  tcp_options {
    destination_port_range {
      min = 443
      max = 443
    }
  }
}

resource "oci_core_network_security_group_security_rule" "lb_ingress_icmp" {
  network_security_group_id = oci_core_network_security_group.load_balancers.id
  direction                 = "INGRESS"
  protocol                  = "1" # ICMP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Allow ICMP Path Discovery"

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "lb_egress_all" {
  network_security_group_id = oci_core_network_security_group.load_balancers.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow all egress from load balancers"
}

# NSG Rules - Nodes
resource "oci_core_network_security_group_security_rule" "nodes_ingress_from_nodes" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.nodes.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow node-to-node communication"
}

resource "oci_core_network_security_group_security_rule" "nodes_ingress_from_control_plane" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = oci_core_network_security_group.control_plane.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow control plane to communicate with nodes"
}

resource "oci_core_network_security_group_security_rule" "nodes_ingress_from_pods" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.pods.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow pods to communicate with nodes"
}

resource "oci_core_network_security_group_security_rule" "nodes_ingress_kubelet" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = local.vcn_cidr
  source_type               = "CIDR_BLOCK"
  description               = "Allow kubelet API access"

  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nodes_ingress_nodeport" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = local.vcn_cidr
  source_type               = "CIDR_BLOCK"
  description               = "Allow NodePort services"

  tcp_options {
    destination_port_range {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_network_security_group_security_rule" "nodes_ingress_icmp" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "1" # ICMP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Allow ICMP Path Discovery"

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "nodes_egress_all" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow all egress from nodes"
}

# NSG Rules - Pods
resource "oci_core_network_security_group_security_rule" "pods_ingress_from_pods" {
  network_security_group_id = oci_core_network_security_group.pods.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.pods.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow pod-to-pod communication"
}

resource "oci_core_network_security_group_security_rule" "pods_ingress_from_nodes" {
  network_security_group_id = oci_core_network_security_group.pods.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.nodes.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow nodes to communicate with pods"
}

resource "oci_core_network_security_group_security_rule" "pods_ingress_from_control_plane" {
  network_security_group_id = oci_core_network_security_group.pods.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.control_plane.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow control plane to communicate with pods"
}

resource "oci_core_network_security_group_security_rule" "pods_ingress_icmp" {
  network_security_group_id = oci_core_network_security_group.pods.id
  direction                 = "INGRESS"
  protocol                  = "1" # ICMP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Allow ICMP Path Discovery"

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "pods_egress_all" {
  network_security_group_id = oci_core_network_security_group.pods.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Allow all egress from pods"
}

# NSG Rules - Storage (for File Storage Service - FSS)
resource "oci_core_network_security_group_security_rule" "storage_ingress_nfs_tcp_111" {
  network_security_group_id = oci_core_network_security_group.storage.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = oci_core_network_security_group.nodes.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow NFS RPC traffic from nodes"

  tcp_options {
    destination_port_range {
      min = 111
      max = 111
    }
  }
}

resource "oci_core_network_security_group_security_rule" "storage_ingress_nfs_udp_111" {
  network_security_group_id = oci_core_network_security_group.storage.id
  direction                 = "INGRESS"
  protocol                  = "17" # UDP
  source                    = oci_core_network_security_group.nodes.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow NFS RPC traffic from nodes"

  udp_options {
    destination_port_range {
      min = 111
      max = 111
    }
  }
}

resource "oci_core_network_security_group_security_rule" "storage_ingress_nfs_tcp_2048_2050" {
  network_security_group_id = oci_core_network_security_group.storage.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = oci_core_network_security_group.nodes.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow NFS data traffic from nodes"

  tcp_options {
    destination_port_range {
      min = 2048
      max = 2050
    }
  }
}

resource "oci_core_network_security_group_security_rule" "storage_ingress_nfs_udp_2048_2050" {
  network_security_group_id = oci_core_network_security_group.storage.id
  direction                 = "INGRESS"
  protocol                  = "17" # UDP
  source                    = oci_core_network_security_group.nodes.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Allow NFS data traffic from nodes"

  udp_options {
    destination_port_range {
      min = 2048
      max = 2050
    }
  }
}

resource "oci_core_network_security_group_security_rule" "storage_egress_to_nodes_tcp_111" {
  network_security_group_id = oci_core_network_security_group.storage.id
  direction                 = "EGRESS"
  protocol                  = "6" # TCP
  destination               = oci_core_network_security_group.nodes.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow NFS responses to nodes"

  tcp_options {
    source_port_range {
      min = 111
      max = 111
    }
  }
}

resource "oci_core_network_security_group_security_rule" "storage_egress_to_nodes_udp_111" {
  network_security_group_id = oci_core_network_security_group.storage.id
  direction                 = "EGRESS"
  protocol                  = "17" # UDP
  destination               = oci_core_network_security_group.nodes.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow NFS responses to nodes"

  udp_options {
    source_port_range {
      min = 111
      max = 111
    }
  }
}

resource "oci_core_network_security_group_security_rule" "storage_egress_to_nodes_tcp_2048_2050" {
  network_security_group_id = oci_core_network_security_group.storage.id
  direction                 = "EGRESS"
  protocol                  = "6" # TCP
  destination               = oci_core_network_security_group.nodes.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow NFS data responses to nodes"

  tcp_options {
    source_port_range {
      min = 2048
      max = 2050
    }
  }
}

resource "oci_core_network_security_group_security_rule" "storage_egress_to_nodes_udp_2048_2050" {
  network_security_group_id = oci_core_network_security_group.storage.id
  direction                 = "EGRESS"
  protocol                  = "17" # UDP
  destination               = oci_core_network_security_group.nodes.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Allow NFS data responses to nodes"

  udp_options {
    source_port_range {
      min = 2048
      max = 2050
    }
  }
}
