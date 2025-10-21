// =====================================================================================
// VPC Network
// =====================================================================================

resource "google_compute_network" "main" {
  name                            = local.vpc_name
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = false

  project = local.project
}

// =====================================================================================
// Subnets
// =====================================================================================

resource "google_compute_subnetwork" "main" {
  for_each = local.node_subnets

  name                     = "${local.prefix}-${each.key}"
  ip_cidr_range            = each.value.cidr
  region                   = local.region
  network                  = google_compute_network.main.id
  private_ip_google_access = try(each.value.privateGoogleAccess, true)

  project = local.project

  # Secondary IP ranges for GKE pods and services
  dynamic "secondary_ip_range" {
    for_each = try(local.secondary_ranges[each.key].pods, null) != null ? [1] : []
    content {
      range_name    = local.secondary_ranges[each.key].pods.rangeName
      ip_cidr_range = local.secondary_ranges[each.key].pods.cidr
    }
  }

  dynamic "secondary_ip_range" {
    for_each = try(local.secondary_ranges[each.key].services, null) != null ? [1] : []
    content {
      range_name    = local.secondary_ranges[each.key].services.rangeName
      ip_cidr_range = local.secondary_ranges[each.key].services.cidr
    }
  }

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

// =====================================================================================
// Cloud Router (for NAT)
// =====================================================================================

resource "google_compute_router" "main" {
  count = local.nat_enabled ? 1 : 0

  name    = "${local.prefix}-router"
  network = google_compute_network.main.id
  region  = local.region
  project = local.project
}

// =====================================================================================
// Cloud NAT
// =====================================================================================

resource "google_compute_router_nat" "main" {
  count = local.nat_enabled ? 1 : 0

  name                               = "${local.prefix}-nat"
  router                             = google_compute_router.main[0].name
  region                             = local.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = local.nat_source_subnetwork_ip_ranges
  min_ports_per_vm                   = local.nat_min_ports_per_vm

  project = local.project

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

// =====================================================================================
// Firewall Rules
// =====================================================================================

resource "google_compute_firewall" "rules" {
  for_each = {
    for rule in try(local.config.network.firewallRules, []) :
    rule.name => rule
  }

  name      = "${local.prefix}-${each.key}"
  network   = google_compute_network.main.name
  direction = try(each.value.direction, "INGRESS")
  priority  = try(each.value.priority, 1000)
  project   = local.project

  source_ranges = try(each.value.sourceRanges, null)
  target_tags   = try(each.value.targetTags, null)

  dynamic "allow" {
    for_each = try(each.value.allowed, [])
    content {
      protocol = allow.value.protocol
      ports    = try(allow.value.ports, null)
    }
  }

  dynamic "deny" {
    for_each = try(each.value.denied, [])
    content {
      protocol = deny.value.protocol
      ports    = try(deny.value.ports, null)
    }
  }
}

// =====================================================================================
// Firewall rule for GKE master to nodes
// =====================================================================================

resource "google_compute_firewall" "gke_master_to_nodes" {
  name    = "${local.prefix}-gke-master-to-nodes"
  network = google_compute_network.main.name
  project = local.project

  direction = "INGRESS"
  priority  = 1000

  source_ranges = [local.master_ipv4_cidr_block]

  allow {
    protocol = "tcp"
    ports    = ["443", "10250"]
  }

  allow {
    protocol = "udp"
  }

  target_tags = ["gke-${local.prefix}"]
}

// =====================================================================================
// Firewall rule for GKE nodes
// =====================================================================================

resource "google_compute_firewall" "gke_nodes" {
  name    = "${local.prefix}-gke-nodes"
  network = google_compute_network.main.name
  project = local.project

  direction = "INGRESS"
  priority  = 1000

  source_tags = ["gke-${local.prefix}"]
  target_tags = ["gke-${local.prefix}"]

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "esp"
  }

  allow {
    protocol = "ah"
  }

  allow {
    protocol = "sctp"
  }
}
