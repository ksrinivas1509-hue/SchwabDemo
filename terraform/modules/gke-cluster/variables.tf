variable "project_id" {
  type = string
}

variable "name" {
  description = "Cluster name, e.g. gke-primary."
  type        = string
}

variable "location" {
  description = "Zone (zonal cluster, default) or region (if var.regional = true)."
  type        = string
}

variable "regional" {
  description = "Set true for a regional (3-zone) control plane. Default true — see docs/DESIGN.md §2."
  type        = bool
  default     = true
}

variable "node_locations" {
  description = "Zones the node pools run in. Leave empty to let GKE pick (all zones in the region for a regional cluster, which triples node count). Set to a single zone to keep node compute cost flat while still getting a regional, multi-zone control plane."
  type        = list(string)
  default     = []
}

variable "network_self_link" {
  type = string
}

variable "subnet_self_link" {
  type = string
}

variable "pods_range_name" {
  type = string
}

variable "services_range_name" {
  type = string
}

variable "private_nodes" {
  type    = bool
  default = true
}

variable "master_ipv4_cidr_block" {
  description = "Must not overlap any other cluster's master CIDR if both are peered to the same VPC."
  type        = string
}

variable "web_pool_machine_type" {
  type    = string
  default = "e2-standard-2"
}

variable "web_pool_min_nodes" {
  type    = number
  default = 1
}

variable "web_pool_max_nodes" {
  type    = number
  default = 3
}

variable "system_pool_machine_type" {
  type    = string
  default = "e2-small"
}

variable "system_pool_min_nodes" {
  type    = number
  default = 1
}

variable "system_pool_max_nodes" {
  type    = number
  default = 2
}
