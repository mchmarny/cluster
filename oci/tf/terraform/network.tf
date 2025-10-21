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

  # Egress rules
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }

  freeform_tags = local.freeform_tags
}
