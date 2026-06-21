variable "project_id" {
  type = string
}

variable "memberships" {
  description = "Map of membership name => cluster self_link to register to the Fleet."
  type        = map(string)
}

variable "config_membership_name" {
  description = "Which key in var.memberships is the Multi-Cluster Ingress config cluster."
  type        = string
  default     = "gke-primary"
}

variable "enable_ingress_feature" {
  description = "Whether to enable the multiclusteringress Fleet feature via Terraform. Default false — see docs/IMPLEMENTATION.md Step 7 for why this is applied via gcloud instead on first run; flip true once membership IDs are confirmed stable."
  type        = bool
  default     = false
}
