// =====================================================================================
// VCN (holds the tenancy-validation precondition)
// =====================================================================================

resource "oci_core_vcn" "main" {
  compartment_id = local.compartment
  cidr_blocks    = [local.vcn_cidr]
  display_name   = "${local.prefix}-vcn"
  dns_label      = "okevcn"
  freeform_tags  = local.tags

  // Tenancy validation: the configured tenancy OCID must resolve and match.
  // OCI lacks a clean caller-identity data source, so we assert the resolved
  // tenancy id equals local.tenancy (data.oci_identity_tenancy.this succeeds
  // only if the caller can read the configured tenancy).
  lifecycle {
    precondition {
      condition     = data.oci_identity_tenancy.this.id == local.tenancy
      error_message = "Invalid OCI tenancy (want: ${local.tenancy}, got: ${data.oci_identity_tenancy.this.id})."
    }
  }
}

// =====================================================================================
// Gateways
// =====================================================================================

// Internet gateway — egress for public subnets (service load balancers when
// public, and public control-plane endpoint if enabled).
resource "oci_core_internet_gateway" "main" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-igw"
  enabled        = true
  freeform_tags  = local.tags
}

// NAT gateway — egress for private subnets (nodes, pods) without inbound.
resource "oci_core_nat_gateway" "main" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-nat"
  freeform_tags  = local.tags
}

// Service gateway — private access to OCI services (Object Storage, etc.),
// including the Terraform state backend over the OCI backbone.
resource "oci_core_service_gateway" "main" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-svcgw"
  freeform_tags  = local.tags

  services {
    // "All <region> Services In Oracle Services Network" is the last entry.
    service_id = data.oci_core_services.all.services[length(data.oci_core_services.all.services) - 1].id
  }
}

// =====================================================================================
// Route tables
// =====================================================================================

// Public route table — default route via the internet gateway.
resource "oci_core_route_table" "public" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-public-rt"
  freeform_tags  = local.tags

  route_rules {
    network_entity_id = oci_core_internet_gateway.main.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    description       = "Default route via internet gateway"
  }
}

// Private route table — default route via NAT, OCI services via service gateway.
resource "oci_core_route_table" "private" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-private-rt"
  freeform_tags  = local.tags

  route_rules {
    network_entity_id = oci_core_nat_gateway.main.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    description       = "Default route via NAT gateway"
  }

  route_rules {
    network_entity_id = oci_core_service_gateway.main.id
    destination       = data.oci_core_services.all.services[length(data.oci_core_services.all.services) - 1].cidr_block
    destination_type  = "SERVICE_CIDR_BLOCK"
    description       = "OCI services via service gateway"
  }
}

// =====================================================================================
// Subnets
// =====================================================================================

// Control-plane endpoint subnet. Public route only when a public endpoint is
// requested; otherwise private (NAT/service gateway).
resource "oci_core_subnet" "control_plane" {
  compartment_id             = local.compartment
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = local.cp_subnet_cidr
  display_name               = "${local.prefix}-cp"
  dns_label                  = "cp"
  prohibit_public_ip_on_vnic = !local.is_public_ip_enabled
  route_table_id             = local.is_public_ip_enabled ? oci_core_route_table.public.id : oci_core_route_table.private.id
  security_list_ids          = [oci_core_vcn.main.default_security_list_id]
  freeform_tags              = local.tags
}

// System node subnet (private).
resource "oci_core_subnet" "system" {
  compartment_id             = local.compartment
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = local.system_subnet_cidr
  display_name               = "${local.prefix}-system"
  dns_label                  = "system"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_vcn.main.default_security_list_id]
  freeform_tags              = local.tags
}

// Worker node subnet (private).
resource "oci_core_subnet" "worker" {
  compartment_id             = local.compartment
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = local.worker_subnet_cidr
  display_name               = "${local.prefix}-worker"
  dns_label                  = "worker"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_vcn.main.default_security_list_id]
  freeform_tags              = local.tags
}

// Pod subnet (private) — required by the OCI_VCN_IP_NATIVE CNI.
resource "oci_core_subnet" "pod" {
  compartment_id             = local.compartment
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = local.pod_subnet_cidr
  display_name               = "${local.prefix}-pod"
  dns_label                  = "pod"
  prohibit_public_ip_on_vnic = true
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_vcn.main.default_security_list_id]
  freeform_tags              = local.tags
}

// Service load balancer subnet. Public by default so ingress LBs are reachable.
resource "oci_core_subnet" "lb" {
  compartment_id             = local.compartment
  vcn_id                     = oci_core_vcn.main.id
  cidr_block                 = local.lb_subnet_cidr
  display_name               = "${local.prefix}-lb"
  dns_label                  = "lb"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_vcn.main.default_security_list_id]
  freeform_tags              = local.tags
}

// =====================================================================================
// Network Security Groups
// =====================================================================================

// Control-plane endpoint NSG.
resource "oci_core_network_security_group" "control_plane" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-cp-nsg"
  freeform_tags  = local.tags
}

// Worker/system node NSG.
resource "oci_core_network_security_group" "nodes" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-nodes-nsg"
  freeform_tags  = local.tags
}

// Pod NSG (OCI_VCN_IP_NATIVE).
resource "oci_core_network_security_group" "pods" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-pods-nsg"
  freeform_tags  = local.tags
}

// =====================================================================================
// NSG rules — control plane
// =====================================================================================

// Allowed CIDRs (config list + caller egress) may reach the Kubernetes API (6443).
resource "oci_core_network_security_group_security_rule" "cp_ingress_api" {
  for_each = toset(local.allowed_cidrs)

  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6" // TCP
  source                    = each.value
  source_type               = "CIDR_BLOCK"
  description               = "Kubernetes API access from allowed CIDR"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

// Nodes -> control plane (API + control-plane comms).
resource "oci_core_network_security_group_security_rule" "cp_ingress_from_nodes" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.nodes.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Control-plane access from worker nodes"

  tcp_options {
    destination_port_range {
      min = 6443
      max = 6443
    }
  }
}

// Control plane egress to nodes (kubelet 10250, all TCP to node NSG).
resource "oci_core_network_security_group_security_rule" "cp_egress_to_nodes" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = oci_core_network_security_group.nodes.id
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Control-plane to node kubelet/webhook traffic"

  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}

// =====================================================================================
// NSG rules — nodes
// =====================================================================================

// Node <-> node all-protocol intra-cluster traffic.
resource "oci_core_network_security_group_security_rule" "nodes_ingress_self" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.nodes.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Node to node traffic"
}

// Control plane -> nodes (kubelet, webhooks).
resource "oci_core_network_security_group_security_rule" "nodes_ingress_from_cp" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.control_plane.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Kubelet/webhook traffic from control plane"

  tcp_options {
    destination_port_range {
      min = 10250
      max = 10250
    }
  }
}

// Pods -> nodes (pod networking within the cluster).
resource "oci_core_network_security_group_security_rule" "nodes_ingress_from_pods" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.pods.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Pod to node traffic"
}

// Node egress — all destinations (NAT/service-gateway constrain reachability).
resource "oci_core_network_security_group_security_rule" "nodes_egress_all" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Node egress"
}

// =====================================================================================
// NSG rules — pods
// =====================================================================================

// Node/pod -> pods (all intra-cluster pod traffic).
resource "oci_core_network_security_group_security_rule" "pods_ingress_self" {
  network_security_group_id = oci_core_network_security_group.pods.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.pods.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Pod to pod traffic"
}

resource "oci_core_network_security_group_security_rule" "pods_ingress_from_nodes" {
  network_security_group_id = oci_core_network_security_group.pods.id
  direction                 = "INGRESS"
  protocol                  = "all"
  source                    = oci_core_network_security_group.nodes.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Node to pod traffic"
}

// Control plane -> pods (webhooks served by pods).
resource "oci_core_network_security_group_security_rule" "pods_ingress_from_cp" {
  network_security_group_id = oci_core_network_security_group.pods.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = oci_core_network_security_group.control_plane.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Webhook traffic from control plane to pods"
}

resource "oci_core_network_security_group_security_rule" "pods_egress_all" {
  network_security_group_id = oci_core_network_security_group.pods.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Pod egress"
}
