resource "google_compute_network" "vpc" {
  project                 = var.project_id
  name                    = "vpc-gke-demo"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "gke_primary" {
  project       = var.project_id
  name          = "snet-gke-primary"
  network       = google_compute_network.vpc.id
  region        = var.region_primary
  ip_cidr_range = "10.10.0.0/20"

  secondary_ip_range {
    range_name    = "pods-primary"
    ip_cidr_range = "10.20.0.0/14"
  }
  secondary_ip_range {
    range_name    = "svc-primary"
    ip_cidr_range = "10.24.0.0/20"
  }

  private_ip_google_access = true
}

resource "google_compute_subnetwork" "gke_secondary" {
  project       = var.project_id
  name          = "snet-gke-secondary"
  network       = google_compute_network.vpc.id
  region        = var.region_secondary
  ip_cidr_range = "10.11.0.0/20"

  secondary_ip_range {
    range_name    = "pods-secondary"
    ip_cidr_range = "10.28.0.0/14"
  }
  secondary_ip_range {
    range_name    = "svc-secondary"
    ip_cidr_range = "10.34.0.0/20"
  }

  private_ip_google_access = true
}

resource "google_compute_subnetwork" "lb" {
  project       = var.project_id
  name          = "snet-lb"
  network       = google_compute_network.vpc.id
  region        = var.region_primary
  ip_cidr_range = "10.40.0.0/24"
}

resource "google_compute_subnetwork" "ops" {
  project       = var.project_id
  name          = "snet-ops"
  network       = google_compute_network.vpc.id
  region        = var.region_primary
  ip_cidr_range = "10.41.0.0/24"
}

# --- Cloud NAT, one per region, so private GKE nodes get outbound egress ---

resource "google_compute_router" "router" {
  for_each = {
    primary   = { region = var.region_primary }
    secondary = { region = var.region_secondary }
  }

  project = var.project_id
  name    = "router-${each.value.region}"
  region  = each.value.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  for_each = google_compute_router.router

  project                            = var.project_id
  name                               = "nat-${each.value.region}"
  router                             = each.value.name
  region                             = each.value.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# --- Firewall: default-deny posture, explicit allows only ---

resource "google_compute_firewall" "allow_iap_ssh" {
  project       = var.project_id
  name          = "allow-iap-ssh"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"] # IAP TCP forwarding range

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "allow_gke_master_webhooks" {
  project   = var.project_id
  name      = "allow-gke-master-webhooks"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  # GKE auto-creates its own master->node firewall rule scoped to each cluster's
  # actual master_ipv4_cidr_block (outside our control, managed by Google) — this
  # rule is a defense-in-depth baseline for intra-VPC webhook traffic, not the rule
  # actually carrying control-plane traffic.
  source_ranges = ["10.0.0.0/8"]
  target_tags   = ["gke-node"]

  allow {
    protocol = "tcp"
    ports    = ["8443", "9443", "15017"]
  }
}

resource "google_compute_firewall" "allow_gclb_health_checks" {
  project   = var.project_id
  name      = "allow-gclb-health-checks"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  # Google Cloud Load Balancer health-checker source ranges (fixed, documented by
  # Google). Multi-Cluster Ingress's container-native NEGs health-check pods
  # directly — without this rule every backend NEG shows UNHEALTHY and the LB
  # returns nothing, even though the pods themselves are perfectly healthy.
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["gke-node"]

  allow {
    protocol = "tcp"
  }
}

resource "google_compute_firewall" "allow_intra_vpc" {
  project       = var.project_id
  name          = "allow-intra-vpc"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = ["10.0.0.0/8"]

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
}

# --- Private Service Access, required for Cloud SQL private IP ---

resource "google_compute_global_address" "psa_range" {
  project       = var.project_id
  name          = "psa-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  address       = "10.50.0.0"
  network       = google_compute_network.vpc.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_range.name]
}
