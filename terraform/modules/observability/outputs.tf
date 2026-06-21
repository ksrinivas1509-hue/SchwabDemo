output "artifact_registry_repo" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.apps.repository_id}"
}

output "cloudsql_connection_name" {
  value = google_sql_database_instance.orders_db.connection_name
}

output "cloudsql_private_ip" {
  value = google_sql_database_instance.orders_db.private_ip_address
}

output "bigquery_dataset" {
  value = google_bigquery_dataset.logs_export.dataset_id
}

output "catalog_service_sa_email" {
  value = google_service_account.catalog_service.email
}

output "orders_service_sa_email" {
  value = google_service_account.orders_service.email
}

output "grafana_sa_email" {
  value = google_service_account.grafana.email
}

output "orders_db_secret_id" {
  value = google_secret_manager_secret.orders_db_password.secret_id
}

output "cloud_armor_policy_name" {
  value = google_compute_security_policy.waf.name
}
