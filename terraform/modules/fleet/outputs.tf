output "membership_ids" {
  value = { for k, m in google_gke_hub_membership.members : k => m.membership_id }
}
