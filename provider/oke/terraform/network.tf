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
    service_id = data.oci_core_services.all.services[0].id
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
    destination       = data.oci_core_services.all.services[0].cidr_block
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
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.main.id
  cidr_block     = local.cp_subnet_cidr
  display_name   = "${local.prefix}-cp"
  dns_label      = "cp"
  // Public IPs stay allowed so isPublicIpEnabled can flip in place: the
  // subnet flag is immutable and replacing the subnet replaces the cluster.
  // The endpoint gets a public IP only when isPublicIpEnabled is true.
  prohibit_public_ip_on_vnic = false
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

// The OKE cloud controller writes LoadBalancer listener rules into the LB
// subnet's security list. A dedicated list keeps those rules off the subnets
// that share the VCN default list, notably the control-plane endpoint subnet
// whose API access is gated only by its NSG. It starts with the default list's
// egress (LB to backends) and no ingress; listeners are added by the
// controller.
resource "oci_core_security_list" "lb" {
  compartment_id = local.compartment
  vcn_id         = oci_core_vcn.main.id
  display_name   = "${local.prefix}-lb-sl"
  freeform_tags  = local.tags

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
    stateless   = false
  }

  // Rules after creation are owned by the cloud controller, not Terraform.
  lifecycle {
    ignore_changes = [ingress_security_rules, egress_security_rules]
  }
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
  security_list_ids          = [oci_core_security_list.lb.id]
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
//
// Rule set follows the OKE security rule reference for VCN-native pod
// networking: nodes and pods reach the API endpoint on 6443 and 12250
// (kubelet/pod -> control-plane proxy), the endpoint reaches nodes and pods on
// all TCP (kubelet, webhooks), and ICMP 3/4 is open for path MTU discovery.

locals {
  oci_services_cidr = data.oci_core_services.all.services[0].cidr_block

  // Ports nodes and pods use to reach the control plane.
  cp_ports = toset(["6443", "12250"])

  // NSGs whose members talk to the control plane.
  cp_clients = {
    nodes = oci_core_network_security_group.nodes.id
    pods  = oci_core_network_security_group.pods.id
  }

  cp_client_rules = {
    for pair in setproduct(keys(local.cp_clients), local.cp_ports) :
    "${pair[0]}-${pair[1]}" => { source = local.cp_clients[pair[0]], port = tonumber(pair[1]) }
  }
}

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

// Nodes and pods -> control plane (API 6443, control-plane proxy 12250).
resource "oci_core_network_security_group_security_rule" "cp_ingress_clients" {
  for_each = local.cp_client_rules

  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = each.value.source
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Control-plane access (${each.key})"

  tcp_options {
    destination_port_range {
      min = each.value.port
      max = each.value.port
    }
  }
}

// Path MTU discovery from nodes.
resource "oci_core_network_security_group_security_rule" "cp_ingress_icmp" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "INGRESS"
  protocol                  = "1" // ICMP
  source                    = oci_core_network_security_group.nodes.id
  source_type               = "NETWORK_SECURITY_GROUP"
  description               = "Path discovery from nodes"

  icmp_options {
    type = 3
    code = 4
  }
}

// Control plane -> nodes and pods (kubelet, webhooks served by pods).
resource "oci_core_network_security_group_security_rule" "cp_egress_clients" {
  for_each = local.cp_clients

  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = each.value
  destination_type          = "NETWORK_SECURITY_GROUP"
  description               = "Control-plane to ${each.key}"
}

// Control plane -> OCI services (OKE management plane via service gateway).
resource "oci_core_network_security_group_security_rule" "cp_egress_services" {
  network_security_group_id = oci_core_network_security_group.control_plane.id
  direction                 = "EGRESS"
  protocol                  = "6"
  destination               = local.oci_services_cidr
  destination_type          = "SERVICE_CIDR_BLOCK"
  description               = "Control-plane to OCI services"
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
  description               = "Control-plane to node traffic"
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

// Service load balancers -> node ports and kube-proxy health checks.
resource "oci_core_network_security_group_security_rule" "nodes_ingress_from_lb" {
  for_each = { nodeports = [30000, 32767], healthz = [10256, 10256] }

  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = local.lb_subnet_cidr
  source_type               = "CIDR_BLOCK"
  description               = "Load balancer to node ${each.key}"

  tcp_options {
    destination_port_range {
      min = each.value[0]
      max = each.value[1]
    }
  }
}

// Path MTU discovery.
resource "oci_core_network_security_group_security_rule" "nodes_ingress_icmp" {
  network_security_group_id = oci_core_network_security_group.nodes.id
  direction                 = "INGRESS"
  protocol                  = "1"
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Path discovery"

  icmp_options {
    type = 3
    code = 4
  }
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
