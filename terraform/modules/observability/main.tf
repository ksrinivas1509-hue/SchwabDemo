# Artifact Registry, Cloud SQL (orders-service backing store), Secret Manager,
# BigQuery dataset + log sinks, Cloud Armor WAF policy, Binary Authorization policy,
# and the Workload-Identity-bound service accounts for both apps plus Grafana.
# See docs/DESIGN.md §5 and §7 for rationale.

# --- Artifact Registry ---

resource "google_artifact_registry_repository" "apps" {
  project       = var.project_id
  location      = var.region
  repository_id = "apps"
  description   = "catalog-service / orders-service container images"
  format        = "DOCKER"
}

# --- Cloud SQL (orders-service) ---
# Password comes in via var.orders_db_password (TF_VAR_orders_db_password or a
# gitignored .auto.tfvars) rather than being generated here, so the same value is
# known to whoever needs to debug a direct `psql` connection without digging it back
# out of Secret Manager first.

resource "google_sql_database_instance" "orders_db" {
  project             = var.project_id
  name                = "orders-db"
  region              = var.region
  database_version    = "POSTGRES_15"
  deletion_protection = var.cloudsql_deletion_protection

  settings {
    tier              = var.cloudsql_tier
    availability_type = "ZONAL" # single-region for this exercise — see docs/DESIGN.md §6 for the cross-region HA follow-up
    user_labels       = var.labels

    ip_configuration {
      ipv4_enabled    = false
      private_network = var.network_self_link
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
    }
  }
}

resource "google_sql_database" "orders" {
  project  = var.project_id
  name     = "orders"
  instance = google_sql_database_instance.orders_db.name
}

resource "google_sql_user" "orders_app" {
  project  = var.project_id
  name     = "orders_app"
  instance = google_sql_database_instance.orders_db.name
  password = var.orders_db_password
}

resource "google_secret_manager_secret" "orders_db_password" {
  project   = var.project_id
  secret_id = "orders-db-password"
  labels    = var.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "orders_db_password" {
  secret      = google_secret_manager_secret.orders_db_password.id
  secret_data = var.orders_db_password
}

# --- BigQuery dataset + log sinks ---

resource "google_bigquery_dataset" "logs_export" {
  project    = var.project_id
  dataset_id = "logs_export"
  location   = var.bigquery_location
  labels     = var.labels
}

resource "google_logging_project_sink" "app_logs" {
  project     = var.project_id
  name        = "sink-app-logs"
  destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.logs_export.dataset_id}"

  filter = "resource.type=\"k8s_container\" AND resource.labels.namespace_name=\"${var.k8s_namespace}\""

  bigquery_options {
    use_partitioned_tables = true
  }

  unique_writer_identity = true
}

resource "google_logging_project_sink" "k8s_events" {
  project     = var.project_id
  name        = "sink-k8s-events"
  destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.logs_export.dataset_id}"

  filter = "logName=\"projects/${var.project_id}/logs/events\" AND resource.type=\"k8s_pod\""

  bigquery_options {
    use_partitioned_tables = true
  }

  unique_writer_identity = true
}

resource "google_bigquery_dataset_iam_member" "app_logs_writer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.logs_export.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.app_logs.writer_identity
}

resource "google_bigquery_dataset_iam_member" "k8s_events_writer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.logs_export.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.k8s_events.writer_identity
}

# --- Cloud Armor WAF ---
# Attached to the global LB's backends declaratively via a Kubernetes BackendConfig
# (cloud.google.com/backend-config annotation on each Service) — see
# k8s/base/*/backendconfig.yaml — rather than a post-hoc `gcloud` patch, since
# Multi-Cluster Ingress provisions the backend services dynamically and BackendConfig
# is the supported way to influence them from outside Terraform's graph.

resource "google_compute_security_policy" "waf" {
  project     = var.project_id
  name        = "waf-policy"
  description = "Rate limiting + preconfigured WAF rules for the global LB — see docs/DESIGN.md §7"

  rule {
    action   = "throttle"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 100
        interval_sec = 60
      }
    }
    description = "Rate limit: 100 req/min per source IP"
  }

  rule {
    action   = "deny(403)"
    priority = 2000
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-stable')"
      }
    }
    description = "Block SQL injection (preconfigured WAF rule)"
  }

  rule {
    action   = "deny(403)"
    priority = 2001
    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-stable')"
      }
    }
    description = "Block XSS (preconfigured WAF rule)"
  }

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "Default rule: allow"
  }
}

# --- Binary Authorization ---
# Dry-run: audits every deployment to Cloud Logging but never blocks one — see
# docs/DESIGN.md §7 for why enforced mode (which would need a real attestor/signing
# pipeline we don't have time to build) isn't worth the risk this close to the demo.
# This is a project-singleton resource (one policy per project).

resource "google_binary_authorization_policy" "policy" {
  project = var.project_id

  default_admission_rule {
    evaluation_mode  = "ALWAYS_ALLOW"
    enforcement_mode = "DRYRUN_AUDIT_LOG_ONLY"
  }
}

# --- Service accounts (Workload Identity targets) ---

resource "google_service_account" "catalog_service" {
  project      = var.project_id
  account_id   = "catalog-service-sa"
  display_name = "catalog-service Workload Identity SA (no extra GCP roles needed)"
}

resource "google_service_account" "orders_service" {
  project      = var.project_id
  account_id   = "orders-service-sa"
  display_name = "orders-service Workload Identity SA"
}

resource "google_service_account" "grafana" {
  project      = var.project_id
  account_id   = "grafana-sa"
  display_name = "Grafana Workload Identity SA (BigQuery + Cloud Monitoring read)"
}

resource "google_project_iam_member" "orders_service_cloudsql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.orders_service.email}"
}

resource "google_secret_manager_secret_iam_member" "orders_service_secret_access" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.orders_db_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.orders_service.email}"
}

resource "google_project_iam_member" "grafana_monitoring_viewer" {
  project = var.project_id
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.grafana.email}"
}

resource "google_project_iam_member" "grafana_bigquery_jobuser" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.grafana.email}"
}

resource "google_bigquery_dataset_iam_member" "grafana_bigquery_viewer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.logs_export.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.grafana.email}"
}

# --- Workload Identity bindings (KSA -> GSA) ---
# Namespace/KSA names must match k8s/base/*/serviceaccount.yaml exactly.

resource "google_service_account_iam_member" "catalog_service_wi" {
  service_account_id = google_service_account.catalog_service.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/catalog-service-sa]"
}

resource "google_service_account_iam_member" "orders_service_wi" {
  service_account_id = google_service_account.orders_service.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.k8s_namespace}/orders-service-sa]"
}

resource "google_service_account_iam_member" "grafana_wi" {
  service_account_id = google_service_account.grafana.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[monitoring/grafana]"
}
