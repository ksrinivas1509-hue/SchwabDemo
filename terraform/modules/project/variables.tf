variable "project_id" {
  description = "GCP project ID. Must already exist unless create_project = true."
  type        = string
}

variable "create_project" {
  description = "If true (default), this module creates var.project_id under var.folder_id (or var.org_id) using var.billing_account, or as a standalone org-less project if both are left null. Set false only if the project already exists."
  type        = bool
  default     = true
}

variable "billing_account" {
  description = "Billing account ID, required only if create_project = true."
  type        = string
  default     = null
}

variable "org_id" {
  description = "GCP Organization ID. Leave null if you don't have a GCP Organization."
  type        = string
  default     = null
}

variable "folder_id" {
  description = "GCP Folder ID to create the project under. Leave null to skip the Folder -> Project hierarchy."
  type        = string
  default     = null
}

variable "cicd_account_id" {
  description = "Account ID (not full email) for the CI/CD service account this module creates."
  type        = string
  default     = "cicd-deployer"
}

variable "apis" {
  description = "APIs to enable on the project."
  type        = list(string)
  default = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "gkehub.googleapis.com",
    "multiclusteringress.googleapis.com",
    "multiclusterservicediscovery.googleapis.com",
    "anthos.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "bigquery.googleapis.com",
    "bigquerydatatransfer.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudtrace.googleapis.com",
    "cloudprofiler.googleapis.com",
    "clouderrorreporting.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "binaryauthorization.googleapis.com",
    "containerscanning.googleapis.com",
  ]
}

variable "dev_group" {
  description = "Google Group email for the Dev role bundle. Leave null to skip the binding (e.g. no Workspace org available)."
  type        = string
  default     = null
}

variable "ops_group" {
  description = "Google Group email for the Ops role bundle."
  type        = string
  default     = null
}

variable "sre_group" {
  description = "Google Group email for the SRE role bundle."
  type        = string
  default     = null
}

variable "cicd_service_account_roles" {
  description = "Roles granted to the dedicated CI/CD service account this module creates."
  type        = list(string)
  default     = ["roles/container.developer", "roles/artifactregistry.writer"]
}
