locals {
  primary_location   = var.gke_cluster_locations == "zonal" ? var.zone_primary : var.region_primary
  secondary_location = var.gke_cluster_locations == "zonal" ? var.zone_secondary : var.region_secondary
}

module "project" {
  source = "./modules/project"

  project_id      = var.project_id
  create_project  = var.create_project
  org_id          = var.org_id
  folder_id       = var.folder_id
  billing_account = var.billing_account
  dev_group       = var.dev_group
  ops_group       = var.ops_group
  sre_group       = var.sre_group
}

module "network" {
  source = "./modules/network"

  project_id       = var.project_id
  region_primary   = var.region_primary
  region_secondary = var.region_secondary

  depends_on = [module.project]
}

module "gke_primary" {
  source = "./modules/gke-cluster"

  project_id             = var.project_id
  name                   = "gke-primary"
  location               = local.primary_location
  regional               = var.gke_cluster_locations == "regional"
  node_locations         = var.gke_cluster_locations == "regional" ? [var.zone_primary] : []
  network_self_link      = module.network.network_self_link
  subnet_self_link       = module.network.subnet_primary_self_link
  pods_range_name        = "pods-primary"
  services_range_name    = "svc-primary"
  master_ipv4_cidr_block = var.master_cidr_primary
}

module "gke_secondary" {
  source = "./modules/gke-cluster"

  project_id             = var.project_id
  name                   = "gke-secondary"
  location               = local.secondary_location
  regional               = var.gke_cluster_locations == "regional"
  node_locations         = var.gke_cluster_locations == "regional" ? [var.zone_secondary] : []
  network_self_link      = module.network.network_self_link
  subnet_self_link       = module.network.subnet_secondary_self_link
  pods_range_name        = "pods-secondary"
  services_range_name    = "svc-secondary"
  master_ipv4_cidr_block = var.master_cidr_secondary
}

module "fleet" {
  source = "./modules/fleet"

  project_id = var.project_id
  memberships = {
    "gke-primary"   = module.gke_primary.membership_resource_link
    "gke-secondary" = module.gke_secondary.membership_resource_link
  }
  config_membership_name = "gke-primary"
  enable_ingress_feature = var.enable_mci_feature
}

module "observability" {
  source = "./modules/observability"

  project_id         = var.project_id
  region             = var.region_primary
  network_self_link  = module.network.network_self_link
  orders_db_password = var.orders_db_password

  # Cloud SQL private IP requires the Private Service Access peering
  # (modules/network) to exist first, and the Workload Identity bindings here need
  # the <project>.svc.id.goog pool that only exists once a GKE cluster with
  # workload_identity_config has been created — neither dependency has a direct
  # attribute reference between the modules, so both must be declared explicitly.
  depends_on = [module.network, module.gke_primary, module.gke_secondary]
}
