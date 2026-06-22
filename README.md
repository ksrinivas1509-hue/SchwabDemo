# GKE Observability Demo

A GCP project with two GKE clusters, two Spring Boot web apps, multi-pod deployment,
and full observability (Cloud Logging → BigQuery, Grafana, Cloud Trace/Profiler) —
built against [`instructions`](instructions). Start here, then go to
[`docs/DESIGN.md`](docs/DESIGN.md) (the *why*) and
[`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md) (the *how*, step by step).

## Directory map

| Path | What |
|---|---|
| [`docs/DESIGN.md`](docs/DESIGN.md) | Architecture write-up, naming conventions, design decisions and rationale |
| [`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md) | Ordered, copy-pasteable setup steps, Thu/Fri build → Monday demo-ready |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | Template + anticipated pitfalls for the "one issue you hit" deliverable |
| `terraform/` | All infra: project IAM, VPC/networking, two GKE clusters, Fleet/Multi-Cluster Ingress, Cloud SQL, BigQuery + log sinks, Cloud Armor, Binary Authorization |
| `apps/catalog-service/` | Web Application A — stateless Spring Boot service, in-memory data |
| `apps/orders-service/` | Web Application B — Spring Boot + Cloud SQL (Postgres) via Cloud SQL Auth Proxy |
| `k8s/base/` | Kubernetes manifests (Deployments, Services, HPAs, ServiceAccounts, BackendConfig, Multi-Cluster Ingress/Service) |
| `bigquery/sample_queries.sql` | Sample queries against the `logs_export` dataset |
| `grafana/` | Helm values, datasource/dashboard provisioning, the 4-panel dashboard JSON |
| `scripts/sync-orders-db-secret.sh` | Syncs the Cloud SQL password from Secret Manager into a K8s Secret |

## Quick start

```bash
# 1. Read docs/DESIGN.md once, then follow docs/IMPLEMENTATION.md top to bottom —
#    it's the single source of truth for command order.
cd terraform && cp terraform.tfvars.example terraform.tfvars  # then edit project_id
```

Full sequence (prereqs → `terraform apply` → build/push images → deploy → MCI →
Grafana → BigQuery → demo checklist) is in
[`docs/IMPLEMENTATION.md`](docs/IMPLEMENTATION.md); don't run commands from this
README in isolation, they assume that doc's ordering and exported env vars
(`PROJECT_ID`, `REPO`, `TAG`, etc.).

## Deliverables checklist (per `instructions`)

- [x] Working cluster with accessible application endpoint — live at `http://35.201.107.129` (`/api/catalog`, `/api/orders` both return 200). **Note the `http://`** — this exercise's LB is HTTP-only (no domain available to issue a managed TLS cert against, see `docs/DESIGN.md` §9); pasting the bare IP into a browser will likely auto-upgrade to `https://` and fail. Always use the explicit `http://` scheme.
- [x] Screenshot/export of the Grafana dashboard — deployed, all 4 panels confirmed showing real data as of 2026-06-21
- [x] Sample BigQuery queries demonstrating log analysis — `bigquery/sample_queries.sql`, all verified live against `logs_export` on 2026-06-21 (queries 1, 2, 4, 5 returned real data; query 3 intentionally has no data — needs an LB log sink not built in this exercise, see its own comment)
- [x] Troubleshooting scenario (one real issue + resolution) — `docs/TROUBLESHOOTING.md` "Your Documented Issue": Cloud SQL connection pool exhaustion (12 total real issues documented, this one selected as the submission)
- [x] Infrastructure as Code (Terraform) to reproduce the setup — `terraform/`, applied successfully to `srini-schwab-demo-062020026`
- [x] Architecture diagram — `docs/DESIGN.md` "Architecture at a Glance" (full system) plus §2 (cluster/node pools), §3 (Workload Identity), §4 (request flow), §5 (observability data flow) for the detailed views
- [x] BigQuery schema and sample queries used in Grafana — `bigquery/sample_queries.sql`, `grafana/dashboards/gke-observability.json`, both verified live
- [x] Design decisions and rationale — `docs/DESIGN.md`, especially §9

## Scope note

This builds the architecture as written in `instructions`, with a small number of
deliberate, documented deviations where building the literal thing would cost more
time/risk than it returns before Monday EOD (Binary Authorization/Cloud Armor in
dry-run/audit rather than fully enforced, Cloud Trace/Profiler scoped as a fast-follow
rather than baked into the base apps, the load balancer running HTTP-only since no
domain was available for a managed TLS cert). Every deviation is called out explicitly, with
its reasoning, in `docs/DESIGN.md` — nothing is silently skipped. Project creation
itself is handled by Terraform (`terraform/modules/project`, `create_project = true` by
default), not `gcloud`. GKE clusters use a regional (3-zone) control plane by default
with node pools pinned to a single zone, keeping node compute cost flat — see
`docs/DESIGN.md` §2 for the cost breakdown.
