# Reusable GKE Standard cluster module, instantiated twice from the root module
# (gke-primary / us-central1, gke-secondary / us-east1). VPC-native, private nodes,
# Workload Identity — see docs/DESIGN.md §2 for the zonal-vs-regional and
# Standard-vs-Autopilot rationale.

resource "google_container_cluster" "this" {
  project  = var.project_id
  name     = var.name
  location = var.location

  # Regional clusters default to fanning node pools across all 3 zones in the
  # region (3x node count); pin to var.node_locations (typically one zone) so
  # node compute cost stays flat while the control plane is still multi-zone.
  node_locations = length(var.node_locations) > 0 ? var.node_locations : null

  # Node pools are managed as separate google_container_node_pool resources below;
  # this default pool is created then immediately deleted, which is the standard
  # Terraform pattern for GKE when you want named, purpose-specific pools instead.
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = var.network_self_link
  subnetwork = var.subnet_self_link

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    enable_private_nodes    = var.private_nodes
    enable_private_endpoint = false # public (firewalled) endpoint so kubectl works without a bastion during the exercise — see docs/DESIGN.md §7
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  monitoring_config {
    # Order matters here even though it shouldn't: GKE's API normalizes this list
    # server-side to this exact order, and since the provider treats it as an ordered
    # list (not a set), declaring any other order causes a perpetual phantom diff on
    # every plan/apply.
    enable_components = ["SYSTEM_COMPONENTS", "STORAGE", "HPA", "POD", "DEPLOYMENT"]
    managed_prometheus {
      # GKE's API now rejects DEPLOYMENT/HPA/POD/STORAGE metric packages unless
      # Managed Prometheus is enabled — not optional like it used to be. This doesn't
      # mean Grafana queries Prometheus directly; these metrics still land in Cloud
      # Monitoring (under the prometheus.googleapis.com/ namespace) and are read from
      # there, same as before.
      enabled = true
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  # Deliberately no `fleet {}` block here: setting one auto-registers the cluster as a
  # Hub Membership at the cluster's own region (e.g. locations/us-central1), but
  # modules/fleet's explicit google_gke_hub_membership resource — and everything
  # downstream that references it (docs/IMPLEMENTATION.md Step 7's
  # locations/global/memberships/... path, the multiclusteringress config_membership)
  # — assumes the traditional locations/global membership. Having both fight over the
  # same cluster fails with "cluster is already registered with resource: .../us-east1/
  # memberships/...". Registration is left entirely to modules/fleet.

  # Consults the project's Binary Authorization policy (modules/observability), which
  # is set to dry-run (audit-log only, never blocks) — see docs/DESIGN.md §7.
  binary_authorization {
    evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
  }

  deletion_protection = false
}

resource "google_container_node_pool" "web_pool" {
  project  = var.project_id
  name     = "web-pool"
  cluster  = google_container_cluster.this.name
  location = var.location

  autoscaling {
    min_node_count = var.web_pool_min_nodes
    max_node_count = var.web_pool_max_nodes
  }

  node_config {
    machine_type = var.web_pool_machine_type
    tags         = ["gke-node"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

resource "google_container_node_pool" "system_pool" {
  project  = var.project_id
  name     = "system-pool"
  cluster  = google_container_cluster.this.name
  location = var.location

  autoscaling {
    min_node_count = var.system_pool_min_nodes
    max_node_count = var.system_pool_max_nodes
  }

  node_config {
    machine_type = var.system_pool_machine_type
    tags         = ["gke-node"]

    taint {
      key    = "workload-type"
      value  = "system"
      effect = "NO_SCHEDULE"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
