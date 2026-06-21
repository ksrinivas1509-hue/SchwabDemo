output "cluster_name" {
  value = google_container_cluster.this.name
}

output "location" {
  value = google_container_cluster.this.location
}

output "endpoint" {
  value     = google_container_cluster.this.endpoint
  sensitive = true
}

output "self_link" {
  value = google_container_cluster.this.self_link
}

output "membership_resource_link" {
  description = "Relative resource name for GKE Hub Membership's endpoint.gke_cluster.resource_link. Not the same format as self_link (full API URL with a /v1/ segment) — Hub Membership rejects that format."
  value       = "//container.googleapis.com/${google_container_cluster.this.id}"
}
