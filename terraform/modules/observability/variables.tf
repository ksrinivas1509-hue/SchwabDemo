variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "network_self_link" {
  description = "VPC self link, for Cloud SQL private IP. Caller must ensure the Private Service Access peering exists before this module applies (module depends_on)."
  type        = string
}

variable "bigquery_location" {
  type    = string
  default = "US"
}

variable "cloudsql_tier" {
  type    = string
  default = "db-f1-micro"
}

variable "cloudsql_deletion_protection" {
  description = "Keep true during the exercise so a stray `terraform destroy` doesn't take out demo data. Flip to false only when actually tearing down."
  type        = bool
  default     = true
}

variable "k8s_namespace" {
  type    = string
  default = "apps"
}

variable "orders_db_password" {
  description = "Password for the orders-service Cloud SQL user. Pass via TF_VAR_orders_db_password or a gitignored .auto.tfvars — never commit a real value."
  type        = string
  sensitive   = true
}

variable "labels" {
  type    = map(string)
  default = {}
}
