variable "project_id" {
  description = "GCP project ID. Created by Terraform when create_project = true (default); must already exist if you set create_project = false. See docs/DESIGN.md §1."
  type        = string
}

variable "create_project" {
  description = "If true (default), Terraform creates var.project_id itself — under var.folder_id/var.org_id if you have a GCP Organization, or as a standalone org-less project if both are left null (the common case for personal/trial accounts). Set false only if the project already exists and you just want Terraform to configure it."
  type        = bool
  default     = true
}

variable "org_id" {
  description = "GCP Organization ID, used only when create_project = true. Leave null if you don't have a GCP Organization."
  type        = string
  default     = null
}

variable "folder_id" {
  description = "GCP Folder ID to create the project under, used only when create_project = true. Leave null to skip the Folder -> Project hierarchy."
  type        = string
  default     = null
}

variable "billing_account" {
  description = "Billing account ID to link, required when create_project = true. Find yours with `gcloud billing accounts list`."
  type        = string
  default     = null
}

variable "region_primary" {
  type    = string
  default = "us-central1"
}

variable "zone_primary" {
  type    = string
  default = "us-central1-a"
}

variable "region_secondary" {
  type    = string
  default = "us-east1"
}

variable "zone_secondary" {
  type    = string
  default = "us-east1-b"
}

variable "gke_cluster_locations" {
  description = "\"regional\" (default) uses region_primary/region_secondary as cluster locations for a 3-zone control plane, with node pools pinned to zone_primary/zone_secondary to keep node compute cost flat. \"zonal\" uses zone_primary/zone_secondary for everything, including the control plane. See docs/DESIGN.md §2."
  type        = string
  default     = "regional"
  validation {
    condition     = contains(["zonal", "regional"], var.gke_cluster_locations)
    error_message = "gke_cluster_locations must be \"zonal\" or \"regional\"."
  }
}

variable "master_cidr_primary" {
  description = "GKE master /28 for gke-primary. Must not overlap master_cidr_secondary or any subnet range."
  type        = string
  default     = "172.16.0.0/28"
}

variable "master_cidr_secondary" {
  description = "GKE master /28 for gke-secondary. Must not overlap master_cidr_primary or any subnet range."
  type        = string
  default     = "172.16.0.16/28"
}

variable "dev_group" {
  description = "Google Group email for the Dev IAM role bundle. Leave null to skip the binding (e.g. no Workspace org available)."
  type        = string
  default     = null
}

variable "ops_group" {
  description = "Google Group email for the Ops IAM role bundle."
  type        = string
  default     = null
}

variable "sre_group" {
  description = "Google Group email for the SRE IAM role bundle."
  type        = string
  default     = null
}

variable "enable_mci_feature" {
  description = "Whether Terraform enables the multiclusteringress Fleet feature. Default false — see modules/fleet and docs/IMPLEMENTATION.md Step 7 for why this is applied via gcloud by hand on first run."
  type        = bool
  default     = false
}

variable "orders_db_password" {
  description = "Password for the orders-service Cloud SQL user, stored into Secret Manager by Terraform. Required, no default — pass via TF_VAR_orders_db_password or a gitignored .auto.tfvars, never commit a real value."
  type        = string
  sensitive   = true
}
