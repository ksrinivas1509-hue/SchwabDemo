output "project_number" {
  value = local.project_number
}

output "cicd_service_account_email" {
  value = google_service_account.cicd.email
}

output "enabled_apis" {
  value = [for s in google_project_service.apis : s.service]
}
