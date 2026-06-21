# Project bootstrap: project creation (default) + API enablement + IAM role bundles.
#
# var.create_project = true (default) has Terraform create var.project_id itself —
# under a Folder/Org per docs/DESIGN.md §1's landing-zone hierarchy if org_id/folder_id
# are set, or as a standalone org-less project (the common personal/trial case) if both
# are left null. Billing is linked in the same resource via var.billing_account.
# Set create_project = false only if the project already exists and you just want
# Terraform to configure it (enable APIs, bind IAM) — see docs/IMPLEMENTATION.md Step 1.

resource "google_project" "this" {
  count = var.create_project ? 1 : 0

  name       = var.project_id
  project_id = var.project_id
  org_id     = var.folder_id == null ? var.org_id : null
  folder_id  = var.folder_id

  billing_account = var.billing_account

  lifecycle {
    precondition {
      condition     = var.billing_account != null
      error_message = "billing_account is required when create_project = true. Set it in terraform.tfvars or export TF_VAR_billing_account."
    }
  }
}

data "google_project" "existing" {
  count      = var.create_project ? 0 : 1
  project_id = var.project_id
}

locals {
  project_number = var.create_project ? google_project.this[0].number : data.google_project.existing[0].number
}

resource "google_project_service" "apis" {
  for_each = toset(var.apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false

  depends_on = [google_project.this]
}

locals {
  role_bundles = {
    dev = {
      group = var.dev_group
      roles = ["roles/container.developer", "roles/artifactregistry.writer", "roles/logging.viewer"]
    }
    ops = {
      group = var.ops_group
      roles = ["roles/container.admin", "roles/compute.networkAdmin"]
    }
    sre = {
      group = var.sre_group
      roles = ["roles/monitoring.admin", "roles/logging.admin", "roles/cloudtrace.user"]
    }
  }

  # Flatten to {bundle-role key => {group, role}}, skipping any bundle whose group is null.
  group_role_bindings = {
    for pair in flatten([
      for bundle_name, bundle in local.role_bundles : [
        for role in bundle.roles : {
          key   = "${bundle_name}-${role}"
          group = bundle.group
          role  = role
        }
      ] if bundle.group != null
    ]) : pair.key => pair
  }
}

resource "google_project_iam_member" "group_bindings" {
  for_each = local.group_role_bindings

  project = var.project_id
  role    = each.value.role
  member  = "group:${each.value.group}"

  depends_on = [google_project.this]
}

resource "google_service_account" "cicd" {
  project      = var.project_id
  account_id   = var.cicd_account_id
  display_name = "CI/CD pipeline (no human login)"

  # Without this, Terraform sees no attribute reference to google_project.this and
  # may create this in parallel with the project itself, losing the race against
  # project creation / IAM propagation (404/403 on a brand-new project).
  depends_on = [google_project.this]
}

resource "google_project_iam_member" "cicd_roles" {
  for_each = toset(var.cicd_service_account_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.cicd.email}"
}

# GKE node pools (modules/gke-cluster) run as the default Compute Engine service
# account ("default" in node_config), not a custom SA. On most projects that account
# gets the broad Editor role automatically when compute.googleapis.com is enabled —
# but this project's Org has that automatic-grant behavior disabled (the same security
# default that meant the project creator didn't get automatic Owner either, in §1
# above), so the node SA starts with zero roles: it can't pull images from Artifact
# Registry, and can't write logs/metrics, even though the cluster's logging_config/
# monitoring_config are turned on. These are the minimum roles GKE's own hardening
# guide recommends for a node service account.
resource "google_project_iam_member" "gke_node_default_sa_roles" {
  for_each = toset([
    "roles/artifactregistry.reader",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${local.project_number}-compute@developer.gserviceaccount.com"

  depends_on = [google_project.this]
}
