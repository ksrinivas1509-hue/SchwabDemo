output "gke_primary_cluster_name" {
  value = module.gke_primary.cluster_name
}

output "gke_primary_location" {
  value = module.gke_primary.location
}

output "gke_secondary_cluster_name" {
  value = module.gke_secondary.cluster_name
}

output "gke_secondary_location" {
  value = module.gke_secondary.location
}

output "vpc_self_link" {
  value = module.network.network_self_link
}

output "fleet_membership_ids" {
  value = module.fleet.membership_ids
}

output "artifact_registry_repo" {
  value = module.observability.artifact_registry_repo
}

output "cloudsql_connection_name" {
  value = module.observability.cloudsql_connection_name
}

output "cloudsql_private_ip" {
  value     = module.observability.cloudsql_private_ip
  sensitive = true
}

output "bigquery_dataset" {
  value = module.observability.bigquery_dataset
}

output "catalog_service_sa_email" {
  value = module.observability.catalog_service_sa_email
}

output "orders_service_sa_email" {
  value = module.observability.orders_service_sa_email
}

output "grafana_sa_email" {
  value = module.observability.grafana_sa_email
}

output "orders_db_secret_id" {
  value = module.observability.orders_db_secret_id
}

output "cicd_service_account_email" {
  value = module.project.cicd_service_account_email
}

output "cloud_armor_policy_name" {
  value = module.observability.cloud_armor_policy_name
}
