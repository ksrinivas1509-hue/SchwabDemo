# Troubleshooting Scenario

The spec asks for **one** real issue you hit and how you resolved it. Replace
everything in the "Your Documented Issue" section below with what actually happened —
don't submit the placeholder. The "Anticipated Pitfalls" appendix exists so you have a
fast diagnosis path *while* building, and a backup candidate if, against the odds,
your first pass through `IMPLEMENTATION.md` goes suspiciously smoothly.

## Your Documented Issue

**Issue:** `orders-service` pods crash-looped intermittently for hours overnight on
both GKE clusters, because they collectively exhausted the Cloud SQL instance's
connection limit.

**Symptoms:** One pod alone had racked up 176 restarts by the time it was noticed.
App container logs were frequently completely empty (the process crashed before it
could print anything); `kubectl logs --previous` showed Hibernate failing during
startup:
```
SQL Error: 0, SQLState: 53300
FATAL: remaining connection slots are reserved for non-replication superuser connections
...
Unable to determine Dialect without JDBC metadata
```

**Root cause:** `orders-db` runs on `db-f1-micro` (chosen deliberately for cost),
which caps out around 25 total Postgres connections.
`apps/orders-service/src/main/resources/application.yml` never set
`spring.datasource.hikari.maximum-pool-size`, so every pod defaulted to HikariCP's
built-in 10-connection pool. With 2 replicas x 2 clusters = 4 pods, that's up to 40
requested connections against a ~25-connection ceiling. The failure mode was
self-sustaining: the app's *startup* sequence itself needs a database connection
(Hibernate queries DB metadata to pick a SQL dialect before the app can finish
booting), so a pod that couldn't acquire a connection couldn't even finish starting —
Kubernetes killed it for failing its startup probe, and the replacement pod hit the
identical wall. No external trigger was needed once the pool was sized wrong for the
deployment topology.

**Resolution:** Added `spring.datasource.hikari.maximum-pool-size: 4` to
`application.yml` (4 pods x 4 = 16 connections, safely under the ~25 ceiling with
headroom for `psql`/Grafana sessions). Rebuilt the image, pushed it under a new tag,
updated `k8s/base/orders-service/kustomization.yaml`, and redeployed to both clusters.

Fixing it live surfaced two more lessons worth keeping:
1. Deleting crash-looping pods directly doesn't help — the ReplicaSet's desired count
   is untouched, so it immediately respawns replacements from the *same* unfixed
   generation. The correct move is `kubectl scale rs <old-rs-name> --replicas=0` on
   the specific ReplicaSet you want gone.
2. The crash loop fed back into the Horizontal Pod Autoscaler: every failed Spring
   Boot startup attempt burns real CPU (JVM boot, JIT, Hibernate init) even though the
   app never serves a request. The HPA only sees "CPU usage is high," not *why* — so
   it scaled `orders-service` out from 2 to 6 replicas on both clusters, which briefly
   made the connection exhaustion *worse* before the real fix had fully propagated. No
   manual HPA intervention was needed — once pods stopped crash-looping, real CPU
   dropped well under the 60% target and the HPA reversed itself within its normal
   stabilization window.

**Prevention / what you'd change next time:** Connection pool size has to be sized
against `(replica count) x (pool size per replica)` versus the shared database's
actual connection ceiling — not left at a library default that's reasonable for a
single instance but dangerous once horizontally scaled. Would catch this earlier next
time by checking expected total connection demand against the DB tier's
`max_connections` *before* the first deploy, not after a crash loop reveals it.

---

## Appendix: Anticipated Pitfalls (use one as a starting point if needed)

### 1. Multi-Cluster Ingress VIP never populates / stays empty
- **Symptom:** `kubectl describe mci catalog-ingress` shows no `VIP` after 20+ minutes,
  or backend health stuck `UNKNOWN`.
- **Likely cause:** the Multi-Cluster Ingress *feature* wasn't actually enabled on the
  fleet before applying the `MultiClusterIngress`/`MultiClusterService` objects
  (Step 7 in `IMPLEMENTATION.md` must run `gcloud container fleet ingress enable`
  before `kubectl apply -f k8s/base/ingress/`), or the `MultiClusterService` was
  applied to the wrong cluster (it must exist on **every** member cluster, while
  `MultiClusterIngress` exists only on the **config cluster**).
- **Fix:** `gcloud container fleet ingress describe` to confirm the feature state is
  `ACTIVE` and the config membership is correct; re-apply the MCS objects to both
  clusters if only one has them.

### 2. `orders-service` pod CrashLoopBackOff — can't reach Cloud SQL
- **Symptom:** `cloud-sql-proxy` sidecar logs `dial tcp: connect: connection refused`
  or the app logs a JDBC connection timeout.
- **Likely cause:** the pod's Workload Identity binding (Step 6) doesn't match exactly
  — either the KSA name, namespace, or GSA email has a typo, so the proxy can't mint
  IAM credentials; or `sqladmin.googleapis.com` wasn't enabled before Terraform tried
  to create the instance, leaving it in a bad state.
- **Fix:** `gcloud iam service-accounts get-iam-policy orders-service-sa@$PROJECT_ID...`
  to confirm the `workloadIdentityUser` binding's member string is *exactly*
  `serviceAccount:$PROJECT_ID.svc.id.goog[apps/orders-service-sa]` (namespace/KSA name
  are case-sensitive and must match the manifest).

### 3. Quota or API-not-ready errors mid-`terraform apply`
- **Symptom:** `Error 403: ... API has not been used in project ... before or it is
  disabled`, immediately after `apply` starts, even though `modules/project` enables
  it.
- **Likely cause:** newly-enabled APIs can take 30–60 seconds to propagate; Terraform's
  dependency graph sometimes races a downstream resource against that propagation
  delay on the very first `apply` of a brand-new project.
- **Fix:** simply re-run `terraform apply tfplan` — it's idempotent and the second
  pass succeeds once the API has finished propagating. If it's a real quota limit
  (common for GKE on a brand-new free-trial project: regional CPU quota), request a
  quota bump from the Console (IAM & Admin → Quotas) — can take minutes to hours, so
  check this early, not the night before the demo.

### 4. Grafana BigQuery panel shows "no data" but the query works in the BQ console
- **Likely cause:** the Grafana BigQuery datasource's service account is missing
  `roles/bigquery.jobUser` (can list/query) in addition to `roles/bigquery.dataViewer`
  (can read the dataset) — both are required, and it's easy to grant only one.
- **Fix:** `gcloud projects add-iam-policy-binding $PROJECT_ID --member
  serviceAccount:grafana-sa@$PROJECT_ID.iam.gserviceaccount.com --role
  roles/bigquery.jobUser`.

### 5. `orders-service` pods `ImagePullBackOff` despite a successful `docker push`
- **Symptom:** `kubectl describe pod` shows `403 Forbidden` on the Artifact Registry
  pull, for *every* pod on *every* node, right after a brand-new cluster's first
  deploy.
- **Likely cause:** GKE node pools here run as the default Compute Engine service
  account (`node_config` doesn't set a custom one). On most projects that account gets
  the broad `Editor` role automatically when `compute.googleapis.com` is enabled — but
  some Orgs (including auto-provisioned personal Cloud Identity orgs) have that
  automatic-grant behavior disabled, so the node SA starts with zero roles and can't
  pull images, write logs, or write metrics, even though logging/monitoring are
  enabled on the cluster.
- **Fix:** grant the node SA the minimum roles GKE's hardening guide recommends —
  `roles/artifactregistry.reader`, `roles/logging.logWriter`,
  `roles/monitoring.metricWriter`, `roles/monitoring.viewer`,
  `roles/stackdriver.resourceMetadata.writer` — done via Terraform in
  `modules/project` (`google_project_iam_member.gke_node_default_sa_roles`) so it's
  reproducible, not a one-off `gcloud` command. Then `kubectl rollout restart` the
  stuck deployments so the kubelet retries the pull immediately instead of waiting out
  its backoff.

### 6. App pods crash-loop on the liveness probe before they ever finish starting
- **Symptom:** `kubectl describe pod` shows repeated `Liveness probe failed: ...
  connection refused`, followed by `Killing ... will be restarted`, even though the
  app's own logs show it eventually starts successfully.
- **Likely cause:** Spring Boot cold start under the default `100m` CPU request can
  take well over 30s (JIT warmup while throttled), but a bare `livenessProbe` with
  `initialDelaySeconds: 20, periodSeconds: 15` only allows ~65s worst-case before 3
  consecutive failures kill the container — kubelet ends up restarting the app
  mid-boot, forever.
- **Fix:** add a `startupProbe` (same endpoint, generous `failureThreshold` x
  `periodSeconds` budget, e.g. 30 x 5s = 150s) to both Deployments. It suppresses
  liveness/readiness checks until the app answers once, then hands off to the normal
  tighter probes for steady-state monitoring.

### 7. `orders-service`'s Cloud SQL Auth Proxy logs `invalid instance connection name`
- **Symptom:** proxy sidecar logs `Config error: invalid instance connection name,
  expected PROJECT:REGION:INSTANCE (connection name = "REPLACE_ME")` — the literal
  placeholder string, not a real value.
- **Likely cause:** `k8s/base/orders-service/configmap.yaml` ships with
  `INSTANCE_CONNECTION_NAME: "REPLACE_ME"` as a static placeholder, since the real
  value depends on `$PROJECT_ID` and isn't known until after `terraform apply`.
  `docs/IMPLEMENTATION.md` Step 6 patches it in immediately after the first
  `kubectl apply -k` — but *any later* `apply -k` on `orders-service` (e.g. to roll a
  new image tag, or to add a probe) re-applies that file verbatim and silently
  clobbers the patch back to `"REPLACE_ME"`.
- **Fix:** re-run the `kubectl patch configmap orders-service-config` + `rollout
  restart deploy/orders-service` commands from Step 6 after *every* `apply -k` on
  `orders-service`, not just the first one.

### 8. Multi-Cluster Ingress VIP is assigned but every request hangs / connection reset
- **Symptom:** `kubectl describe mci catalog-ingress` shows a `VIP` and fully-populated
  `Cloud Resources` (NEGs, backend services, forwarding rule) — but `curl` against the
  VIP gets nothing back (curl error 52, "empty reply"), not even a 502.
  `gcloud compute backend-services get-health <name> --global` shows every endpoint as
  `UNHEALTHY` even though the pods themselves are running fine and pass their own
  readiness probes. **Two independent causes stacked here**, fixed one at a time:
- **Cause 1 — firewall:** this exercise's VPC firewall is default-deny with only 3
  narrow allows (IAP SSH, GKE master webhooks, intra-VPC) — no rule let Google's
  load-balancer health checkers reach the nodes. Container-native Ingress (NEGs)
  health-checks pods *directly*, from fixed Google source ranges (`130.211.0.0/22`,
  `35.191.0.0/16`); every check was silently dropped.
  **Fix:** added a firewall rule allowing `tcp` ingress from those ranges to the node
  tag (`modules/network`, `google_compute_firewall.allow_gclb_health_checks`). Turned
  out to be necessary but not sufficient — GKE's own auto-generated `*-mcsd` firewall
  rule already covers these ranges for its own auto-tag, but ours is still good
  defense-in-depth under explicit Terraform control rather than relying on an
  implicit, unmanaged rule.
- **Cause 2 — wrong health check path:** even after fixing the firewall, backends
  stayed unhealthy. The GCE health check GKE auto-generates defaults to `GET /` on
  the serving port — Spring Boot has no mapping there (only `/api/...` and
  `/actuator/...`), so every check got a 404.
  **Fix:** added an explicit `healthCheck` block (`requestPath: /actuator/health/
  readiness`) to both `BackendConfig` resources. That alone didn't take effect either
  — the NEG is actually wired to MCI's per-cluster *derived* Service, not the plain
  `Service` we annotate in `service.yaml`. The `cloud.google.com/backend-config`
  annotation has to go on the `MultiClusterService` object itself
  (`k8s/base/ingress/multiclusterservice-*.yaml`) so the controller propagates it down
  to the derived Service. Once both fixes landed, backends turned healthy within
  ~1-2 minutes (one zone at a time, not simultaneously) and `curl` against the VIP
  returned real `200`s.

### 9. Grafana's "Application error rate" panel always shows 0%, even with real errors
- **Symptom:** the BigQuery-backed error-rate panel renders a flat line at 0 no matter
  how many real `ERROR`-level lines the apps log (confirmed via `kubectl logs` showing
  genuine stack traces at the same timestamps the panel reports zero).
- **Likely cause:** `apps/*/src/main/resources/logback-spring.xml` adds a
  `LogLevelJsonProvider` aimed at emitting a top-level `severity` field so Cloud
  Logging auto-promotes it to `LogEntry.severity` — but it isn't taking effect.
  Checking the BigQuery export schema confirms it: `jsonPayload` only ever contains a
  `level` field (Logstash's default), never `severity`, and the top-level `severity`
  *column* BigQuery exposes is always `INFO`/`DEFAULT` regardless of the real log
  level, because Cloud Logging only auto-promotes a JSON key that's spelled exactly
  `severity`.
- **Fix (applied, no rebuild needed):** query `jsonPayload.level` directly instead of
  the top-level `severity` column — works immediately against data already collected,
  since the real level was always present in the payload, just under the wrong key.
  Updated in `grafana/dashboards/gke-observability.json` and
  `bigquery/sample_queries.sql` (queries 1 and 4).
- **Not yet fixed (optional follow-up):** the logback config itself is still wrong —
  fixing it properly (e.g. `<fieldNames><level>severity</level></fieldNames>` instead
  of the no-op `LogLevelJsonProvider`) would need an app rebuild + redeploy of both
  services. Left alone deliberately to avoid an unnecessary rebuild this close to the
  demo, since the query-level fix already makes the panel correct either way.

### 10. BigQuery panel still empty even after the query fix — plugin can't load at all
- **Symptom:** after fixing the `severity`/`level` query bug (issue #9), the panel
  *still* showed nothing. `kubectl logs` on the Grafana pod showed the
  `doitintl-bigquery-datasource` plugin downloading successfully but then:
  `"Plugin validation failed" pluginId=doitintl-bigquery-datasource error="plugin
  'doitintl-bigquery-datasource' has no signature"`.
- **Likely cause:** modern Grafana refuses to load *unsigned* community plugins by
  default. Setting `GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS` got past that, but
  surfaced the real, unfixable problem underneath: `"Refusing to initialize plugin
  because it's using Angular, which has been disabled" ... "angular plugins are not
  supported"`. Checking `https://grafana.com/api/plugins/doitintl-bigquery-datasource`
  confirmed the plugin is officially `"status": "deprecated"`, last updated Jan 2024,
  and even its newest release is still Angular-based (`"angularDetected": true`).
  Grafana fully removed Angular plugin support — there is no version of this plugin,
  and no config flag, that will ever make it load on a current Grafana.
- **Fix:** switched to `grafana-bigquery-datasource` — Grafana Labs' own signed,
  actively maintained "Google BigQuery" plugin (`orgName: Grafana Labs`,
  `signatureType: grafana`, not Angular). Required two changes beyond just the plugin
  ID: (1) the datasource `type` in `grafana/helm-values.yaml` and
  `grafana/provisioning/datasources/datasources.yaml`, and (2) removing the
  `"format": "time_series"` field from the panel's query target in
  `grafana/dashboards/gke-observability.json` — this plugin rejects that field
  outright (`"invalid format value: time_series"`), where the old plugin required it.
  Verified end-to-end by POSTing the exact panel query to `/api/ds/query` and
  confirming real, non-zero rows — don't just trust "no error in `helm upgrade`",
  since both the signature and Angular failures were silent at the Helm/kubectl layer
  and only showed up in the pod's own logs.

### 11. Cloud Monitoring panels: clicking "Refresh" in Query Inspector does *nothing*
- **Symptom:** the 3 Cloud Monitoring panels (pod restarts, latency, CPU/memory) showed
  "No data." Grafana's own Query Inspector said "No request and response collected
  yet" — and clicking its Refresh button did nothing: confirmed via a live `kubectl
  logs -f` on the Grafana pod that *zero* requests reached the server when the button
  was clicked. No error anywhere, no console exception — the frontend just never
  attempted the query.
- **Red herring along the way:** rebuilding one panel's query through the visual
  query builder (Service → Kubernetes → Container Restart Count) did produce a
  request and real-looking data — but it had silently picked
  `kubernetes.io/anthos/container/restart_count` (an **ALPHA**-launch-stage metric,
  per `metricDescriptors.list`) instead of the **GA** `kubernetes.io/container/
  restart_count` we'd originally queried — both share the literal display name
  "Restart count" in the picker, easy to pick the wrong one. The Alpha metric turned
  out to be too sparse to be useful (data appeared once, then read empty minutes
  later) — not the actual fix.
- **Real root cause:** every one of our hand-written `timeSeriesList` targets was
  missing `projectName`. The visual-builder-generated query that *did* fire a request
  had `"projectName": "<project-id>"` set explicitly; ours never did, relying on the
  datasource's configured default project instead. The backend (`/api/ds/query`
  called directly with admin auth) is lenient about this and returns correct data
  either way — which is exactly why every one of this session's backend-side
  verifications kept passing while the real browser kept showing nothing. The
  frontend's query editor, however, appears to treat a target missing `projectName`
  as incomplete and never issues it as a network request at all.
- **Fix:** add `"projectName": "<project-id>"` to every `timeSeriesList` target in
  `grafana/dashboards/gke-observability.json` (all 6 of them, across the 3 affected
  panels) — keeping the original GA metric names and groupBy/reducer/aligner design
  throughout. Also added `envsubst` for the dashboard JSON file itself in
  `docs/IMPLEMENTATION.md`/`docs/DEPLOYMENT_GUIDE.md` Step 12, since `--set-file`
  passes that file through raw with no variable substitution — a `${PROJECT_ID}`
  placeholder inside it would otherwise deploy as a literal, invalid string.
- **Lesson:** when a backend API call succeeds but the browser shows nothing and
  *the UI's own "refresh" control does nothing*, suspect a frontend-side validation
  step silently rejecting an incomplete query model — compare a known-working,
  UI-generated query against the hand-written one field-by-field rather than
  re-testing the same hand-written query against the backend over and over.

### 12. `terraform apply` fails to register clusters to the Fleet — two mechanisms collide
- **Symptom:** `Error: Error creating Membership: ... InvalidValueError for field
  endpoint.gke_cluster.resource_link ... is not a valid path`, and after fixing that,
  `Error: ... intend to register the cluster with resource: .../locations/global/
  memberships/gke-secondary, but the cluster is already registered with resource:
  .../locations/us-east1/memberships/gke-secondary`.
- **Likely cause:** two separate things were both trying to register the same cluster
  to the Fleet. `modules/gke-cluster/main.tf`'s `google_container_cluster` resource
  had a `fleet { project = var.project_id }` block, which auto-registers the cluster
  the instant it's created — but at the cluster's own region, not `locations/global`.
  Separately, `modules/fleet/main.tf` has an explicit `google_gke_hub_membership`
  resource that also registers the cluster, defaulting to `locations/global` (the
  location every other part of this repo assumes). GKE Hub only allows one membership
  per cluster. This was masked at first by an unrelated format bug: the explicit
  membership resource passed `google_container_cluster.self_link` (a full HTTPS API
  URL) where the Hub Membership API expects a relative resource name.
- **Fix:** removed the `fleet {}` block entirely, leaving Fleet registration solely
  owned by the explicit `google_gke_hub_membership` resource. Added a
  `membership_resource_link` output to fix the `resource_link` format at the same
  time. Don't pair a resource's built-in "convenience" auto-registration with a
  separate explicit resource doing the same thing — pick exactly one owner.
