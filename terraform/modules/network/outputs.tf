output "network_self_link" {
  value = google_compute_network.vpc.self_link
}

output "network_name" {
  value = google_compute_network.vpc.name
}

output "subnet_primary_self_link" {
  value = google_compute_subnetwork.gke_primary.self_link
}

output "subnet_secondary_self_link" {
  value = google_compute_subnetwork.gke_secondary.self_link
}

output "psa_connection" {
  value = google_service_networking_connection.psa.peering
}
