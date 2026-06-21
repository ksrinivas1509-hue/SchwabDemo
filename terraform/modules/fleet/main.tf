# Registers both GKE clusters to the project's GKE Fleet (Hub) and, optionally,
# enables the Multi-Cluster Ingress feature pointed at the config cluster.
#
# Why enable_ingress_feature defaults to false: the multiclusteringress feature
# enablement API is picky about membership propagation timing on a brand-new fleet —
# see docs/TROUBLESHOOTING.md item 1. docs/IMPLEMENTATION.md Step 7 runs the
# equivalent `gcloud container fleet ingress enable` by hand the first time, which is
# more forgiving about retries. Once that's confirmed working, flipping this to true
# brings the feature under Terraform management for future applies.

resource "google_gke_hub_membership" "members" {
  for_each = var.memberships

  project       = var.project_id
  membership_id = each.key

  endpoint {
    gke_cluster {
      resource_link = each.value
    }
  }
}

resource "google_gke_hub_feature" "multiclusterservicediscovery" {
  count    = var.enable_ingress_feature ? 1 : 0
  project  = var.project_id
  name     = "multiclusterservicediscovery"
  location = "global"
}

resource "google_gke_hub_feature" "multiclusteringress" {
  count    = var.enable_ingress_feature ? 1 : 0
  project  = var.project_id
  name     = "multiclusteringress"
  location = "global"

  spec {
    multiclusteringress {
      config_membership = google_gke_hub_membership.members[var.config_membership_name].id
    }
  }

  depends_on = [google_gke_hub_feature.multiclusterservicediscovery]
}
