# Step-by-Step Implementation Guide

Companion to [`DESIGN.md`](DESIGN.md) — that doc explains *why*, this one is the ordered
*how*. Commands assume macOS/zsh, `gcloud` CLI installed and authenticated, Terraform
>= 1.5, `kubectl`, `helm` >= 3, Docker (or `gcloud builds submit` if you don't want
Docker running locally), and `mvn`/JDK 17 only if you want to build the Spring Boot
apps outside Docker.

Target: everything below should be runnable Thu/Fri, demo-ready by **Monday EOD**,
walked through live **Tuesday/Wednesday**. Each step says how long it realistically
takes so you can plan the timebox.

---

## Step 0. Prerequisites (15 min)

```bash
gcloud auth login
gcloud auth application-default login
gcloud components install kubectl gke-gcloud-auth-plugin
export USE_GKE_GCLOUD_AUTH_PLUGIN=True   # add to your shell profile

# Pick a globally-unique project id
export PROJECT_ID="schwab-gke-demo-$(date +%s | tail -c 6)"
export BILLING_ACCOUNT_ID="<your-billing-account-id>"   # gcloud billing accounts list
```

If you don't already have one, this is also when to confirm you're on the **free
trial / $300 credit** (new account) or otherwise have a budget alert set. Run this once
the project exists (it's created by Terraform in Step 2, not here):

```bash
# after Step 2's `terraform apply` creates the project, optional but recommended:
gcloud billing budgets create --billing-account=$BILLING_ACCOUNT_ID \
  --display-name="gke-demo-budget" --budget-amount=50 \
  --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0
```

---

## Step 1. Bootstrap the project (2 min)

Terraform creates the project itself (`modules/project`, `var.create_project = true`,
the default) — no manual `gcloud projects create` needed. It links billing in the same
`google_project` resource via `var.billing_account`, and creates a standalone org-less
project if you leave `var.org_id`/`var.folder_id` null (the normal case for a
personal/trial account with no Cloud Identity Organization). All you do here is confirm
your authenticated account (from Step 0) can create projects and has `roles/billing.user`
(or `Billing Account User`) on `$BILLING_ACCOUNT_ID` — true by default for the account
that owns a personal/trial billing account:

```bash
gcloud organizations list   # confirms whether you have an Org/Folder at all — fine if empty
gcloud billing accounts list
```

If `organizations list` returns a row, set `org_id` to that ID in `terraform.tfvars`
(Step 2) — don't assume "personal account" means no Org; Google now auto-provisions a
lightweight Cloud Identity org for some personal Gmail accounts. Leave `folder_id` null
either way (Org → Project alone satisfies the spec's hierarchy ask here).

You'll pass `$PROJECT_ID` and `$BILLING_ACCOUNT_ID` into `terraform.tfvars` in Step 2.

If your authenticated identity does *not* have permission to create projects (e.g. a
locked-down corporate account), set `create_project = false` in `terraform.tfvars`
instead, create the project by hand once, and point Terraform at it:

```bash
gcloud projects create $PROJECT_ID --name="GKE Observability Demo"
gcloud billing projects link $PROJECT_ID --billing-account=$BILLING_ACCOUNT_ID
gcloud config set project $PROJECT_ID
```

---

## Step 2. Terraform init & apply — foundation (30–45 min, mostly waiting on GCP)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set project_id, billing_account, and any group emails you have
# (leave org_id/folder_id null unless you have a GCP Organization)

# orders-service's Cloud SQL password is operator-supplied, not auto-generated —
# export it as an env var so it never touches a file on disk:
export TF_VAR_orders_db_password="$(openssl rand -base64 24)"

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

This single `apply` brings up, in dependency order (see `main.tf`):
1. Project creation + API enablement + IAM (`modules/project`)
2. VPC, subnets, Cloud NAT, firewall, Private Service Access (`modules/network`)
3. Both GKE clusters + node pools (`modules/gke-cluster` x2)
4. Fleet memberships + Multi-Cluster Ingress feature (`modules/fleet`)
5. Artifact Registry repo, Cloud SQL instance + DB + Secret Manager secret,
   BigQuery dataset + log sinks (`modules/observability`)

**Expect this to take 25–40 minutes** — GKE cluster creation alone is ~10–15 min each,
and they're created in parallel by Terraform's graph but Cloud SQL instance creation
(~10 min) and fleet feature enablement can serialize behind them. Good point to grab
coffee; don't `Ctrl-C` mid-apply.

If `apply` fails partway (common first-run causes: an API not yet "warm" right after
enabling it, or a quota needing a request) — re-run `terraform apply tfplan`, it's
idempotent. See `docs/TROUBLESHOOTING.md` for the specific errors we hit.

Capture the outputs you'll need below:
```bash
terraform output
# cluster names/locations, vpc self link, artifact_registry_repo, cloudsql_connection_name,
# bigquery_dataset, fleet_membership_ids
```

---

## Step 3. Get cluster credentials (5 min)

Clusters are regional by default (`var.gke_cluster_locations = "regional"`), so use
`--region`, not `--zone`:

```bash
gcloud container clusters get-credentials gke-primary   --region us-central1 --project $PROJECT_ID
gcloud container clusters get-credentials gke-secondary  --region us-east1    --project $PROJECT_ID

kubectl config rename-context gke_${PROJECT_ID}_us-central1_gke-primary   gke-primary
kubectl config rename-context gke_${PROJECT_ID}_us-east1_gke-secondary    gke-secondary

kubectl --context gke-primary get nodes
kubectl --context gke-secondary get nodes
```

---

## Step 4. Build & push app images (20 min)

```bash
gcloud auth configure-docker us-central1-docker.pkg.dev

export REPO="us-central1-docker.pkg.dev/${PROJECT_ID}/apps"
export TAG=$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M)

for app in catalog-service orders-service; do
  docker build -t "${REPO}/${app}:${TAG}" "apps/${app}"
  docker push "${REPO}/${app}:${TAG}"
done
```

No Docker locally? Use Cloud Build instead, same result, no local daemon needed:
```bash
for app in catalog-service orders-service; do
  gcloud builds submit "apps/${app}" --tag "${REPO}/${app}:${TAG}"
done
```

Update the image tag in the manifests before applying, using each app's own
`k8s/base/<app>/kustomization.yaml`:
```bash
(cd k8s/base/catalog-service && kustomize edit set image catalog-service="${REPO}/catalog-service:${TAG}")
(cd k8s/base/orders-service  && kustomize edit set image orders-service="${REPO}/orders-service:${TAG}")
```
No standalone `kustomize` binary? `kubectl` bundles a build-only version (no `edit` subcommand) — just
hand-edit the `newName:`/`newTag:` fields under `images:` in each `kustomization.yaml` instead.

---

## Step 5. Create namespaces & verify Workload Identity bindings (5 min)

Terraform (`modules/observability`) already created `catalog-service-sa@`,
`orders-service-sa@`, `grafana-sa@` and bound each to a Kubernetes ServiceAccount
*name* (KSA) via `google_service_account_iam_member` — but the GCP project ID isn't
known to the static YAML in `k8s/base/`, so the KSA → GSA link is completed by
annotating the KSA in Step 6 (right after it's created), not baked into the manifest:

```bash
for ctx in gke-primary gke-secondary; do
  kubectl --context $ctx apply -f k8s/base/namespace/
done

# Sanity-check one binding (the GCP side; the KSA side is annotated in Step 6):
gcloud iam service-accounts get-iam-policy \
  "orders-service-sa@${PROJECT_ID}.iam.gserviceaccount.com"
# expect: roles/iam.workloadIdentityUser bound to
# serviceAccount:PROJECT_ID.svc.id.goog[apps/orders-service-sa]
```

---

## Step 6. Sync the Cloud SQL secret, then deploy the apps (15 min)

`orders-service` reads its DB password from a Kubernetes Secret that is **not**
applied via kustomize/Git — it's synced from Secret Manager once per cluster context
right before the Deployment that needs it (see `docs/DESIGN.md` §3 and §7 for why):

```bash
for ctx in gke-primary gke-secondary; do
  ./scripts/sync-orders-db-secret.sh $ctx
done
```

Now deploy both apps and complete the two things the static YAML can't know up front
— the Workload Identity GSA email and the Cloud SQL instance connection name (both
depend on `$PROJECT_ID`, pulled straight from `terraform output`):

```bash
export CATALOG_SA=$(terraform -chdir=terraform output -raw catalog_service_sa_email)
export ORDERS_SA=$(terraform -chdir=terraform output -raw orders_service_sa_email)
export INSTANCE_CONNECTION_NAME=$(terraform -chdir=terraform output -raw cloudsql_connection_name)

for ctx in gke-primary gke-secondary; do
  echo "=== $ctx ==="
  kubectl --context $ctx apply -k k8s/base/catalog-service
  kubectl --context $ctx apply -k k8s/base/orders-service

  kubectl --context $ctx -n apps annotate serviceaccount catalog-service-sa \
    iam.gke.io/gcp-service-account="$CATALOG_SA" --overwrite
  kubectl --context $ctx -n apps annotate serviceaccount orders-service-sa \
    iam.gke.io/gcp-service-account="$ORDERS_SA" --overwrite

  kubectl --context $ctx -n apps patch configmap orders-service-config --type merge \
    -p "{\"data\":{\"INSTANCE_CONNECTION_NAME\":\"${INSTANCE_CONNECTION_NAME}\"}}"
  # the proxy sidecar reads this at container start, so restart pods to pick it up:
  kubectl --context $ctx -n apps rollout restart deploy/orders-service
  # IMPORTANT: `configmap.yaml` ships with INSTANCE_CONNECTION_NAME: "REPLACE_ME" as a
  # static placeholder. Any later `kubectl apply -k k8s/base/orders-service` (e.g. to
  # roll a new image tag) re-applies that file verbatim and silently clobbers this
  # patch back to "REPLACE_ME" — the proxy sidecar then fails every connection with
  # "invalid instance connection name". Re-run the patch+restart above after *every*
  # `apply -k` on orders-service, not just the first one.

  kubectl --context $ctx -n apps rollout status deploy/catalog-service
  kubectl --context $ctx -n apps rollout status deploy/orders-service
done
```

Sanity check from inside the cluster before wiring up the LB:
```bash
kubectl --context gke-primary -n apps run curl --rm -it --image=curlimages/curl -- \
  curl -s http://catalog-service/api/catalog
```

---

## Step 7. Register the Fleet & enable Multi-Cluster Ingress (15 min)

Terraform already created the `google_gke_hub_membership` resources (Step 2); this
step enables the **Ingress** feature itself and points it at the config cluster,
which today is most reliably done via `gcloud` (the Terraform `google_gke_hub_feature`
resource for `multiclusteringress` is included but flagged `enabled = false` by default
in `modules/fleet` — flip it to `true` once you've confirmed the membership IDs match,
or just run the equivalent `gcloud` once, which is what's documented here):

```bash
gcloud container fleet ingress enable \
  --config-membership=projects/${PROJECT_ID}/locations/global/memberships/gke-primary

gcloud container fleet ingress describe
```

Apply the MultiClusterService + MultiClusterIngress objects **only to the config
cluster** (`gke-primary`):
```bash
kubectl --context gke-primary apply -f k8s/base/ingress/
kubectl --context gke-primary -n apps get mcs,mci
```

MCI propagation (creating the NEGs, backend services, and global LB) takes
**10–20 minutes** the first time — this is the single longest "just wait" step
in the whole guide. Watch it with:
```bash
watch kubectl --context gke-primary -n apps describe mci catalog-ingress
```
You're looking for `VIP` to populate and backend health to go green.

---

## Step 8. Point DNS at the LB (5 min, optional)

If you own a domain, create the A record once the MCI VIP is assigned:
```bash
export LB_IP=$(kubectl --context gke-primary -n apps get mci catalog-ingress \
  -o jsonpath='{.status.VIP}')
echo $LB_IP
# create an A record for your domain -> $LB_IP in your DNS provider, or:
gcloud dns record-sets create www.yourapp.example. --zone=<your-managed-zone> \
  --type=A --ttl=300 --rrdatas="${LB_IP}"
```
No domain handy? Demo against `https://$LB_IP` directly (self-signed/Google-managed
cert will warn in a browser without a real hostname — fine for an internal demo, call
it out live rather than scrambling for a domain).

---

## Step 9. (Optional, if time remains) Wire up Cloud Trace / Profiler

Not built into the base apps — see `docs/DESIGN.md` §5 for why this was deliberately
left out of the Monday timebox. If you have time after Steps 10–14 are demo-ready,
here's the smallest path to add each:

**Cloud Trace** — add to each app's `pom.xml`:
```xml
<dependency>
  <groupId>com.google.cloud</groupId>
  <artifactId>spring-cloud-gcp-starter-trace</artifactId>
</dependency>
```
and to `application.yml`: `spring.cloud.gcp.trace.enabled: true` — it auto-instruments
Spring Web requests using the pod's Workload Identity, no other config. Rebuild/push/
redeploy (Steps 4 and 6), generate traffic (Step 11), then:
```bash
gcloud trace list-traces --project $PROJECT_ID | head
```

**Cloud Profiler** — add to each `Dockerfile`, before the `ENTRYPOINT`:
```dockerfile
ADD https://storage.googleapis.com/cloud-profiler/java/latest/profiler_java_agent.so /opt/cprof/profiler_java_agent.so
ENV JAVA_TOOL_OPTIONS="-agentpath:/opt/cprof/profiler_java_agent.so=-cprof_service=catalog-service,-cprof_service_version=1.0.0"
```
(swap the service name for `orders-service` in that app's Dockerfile). Rebuild/push/
redeploy, then check the Profiler tab in the Console after a few minutes of traffic.

Treat both as a stretch goal — don't burn demo-prep time on them if Steps 10–14 aren't
solid yet.

---

## Step 10. Verify the working endpoint (5 min) — Deliverable #1

```bash
curl -sk "https://${LB_IP}/api/catalog" | jq .
curl -sk "https://${LB_IP}/api/orders" | jq .
```
This satisfies "Working cluster with accessible application endpoint." Screenshot the
terminal output or the browser response for the demo.

---

## Step 11. Generate demo traffic (5 min)

```bash
for i in $(seq 1 200); do
  curl -sk "https://${LB_IP}/api/catalog" > /dev/null
  curl -sk "https://${LB_IP}/api/catalog/stress?ms=300" > /dev/null
  curl -sk -X POST "https://${LB_IP}/api/orders" \
    -H 'Content-Type: application/json' \
    -d '{"product":"widget","quantity":1}' > /dev/null
done
# watch HPA react:
kubectl --context gke-primary -n apps get hpa -w
```
Run this for a few minutes so BigQuery/Grafana have non-trivial data before the demo.

---

## Step 12. Deploy Grafana & confirm the dashboard (20 min) — Deliverable #2

```bash
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update

kubectl --context gke-primary create namespace monitoring --dry-run=client -o yaml | \
  kubectl --context gke-primary apply -f -

# helm-values.yaml has ${PROJECT_ID}/${GRAFANA_SA} placeholders (the chart's
# datasources/serviceAccount keys contain literal dots, which makes `helm --set`
# escaping painful — envsubst is simpler). The dashboard JSON has a ${PROJECT_ID}
# placeholder too (the "Pod restart counts" panel's projectName) — --set-file passes
# that file through raw, with no substitution, so it must be envsubst'd separately
# before being handed to --set-file, not used straight from the repo path.
export GRAFANA_SA=$(terraform -chdir=terraform output -raw grafana_sa_email)
envsubst '${PROJECT_ID} ${GRAFANA_SA}' < grafana/helm-values.yaml > /tmp/grafana-values.yaml
envsubst '${PROJECT_ID}' < grafana/dashboards/gke-observability.json > /tmp/gke-observability.json

helm upgrade --install grafana grafana/grafana \
  --kube-context gke-primary \
  --namespace monitoring \
  -f /tmp/grafana-values.yaml \
  --set-file 'dashboards.default.gke-observability.json=/tmp/gke-observability.json'

kubectl --context gke-primary -n monitoring get svc grafana
# get the admin password:
kubectl --context gke-primary -n monitoring get secret grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Port-forward (or use the LoadBalancer IP from the `get svc` above) and open Grafana:
```bash
kubectl --context gke-primary -n monitoring port-forward svc/grafana 3000:80
open http://localhost:3000
```
Datasources (BigQuery + Google Cloud Monitoring) and the 4-panel dashboard are
auto-provisioned from `grafana/provisioning/` and `grafana/dashboards/` — confirm all
4 panels render with real data, then **export/screenshot the dashboard** — this is
Deliverable #2.

---

## Step 13. Run the BigQuery sample queries (10 min) — Deliverable #3

```bash
envsubst < bigquery/sample_queries.sql > /tmp/sample_queries.sql
```

Paste each labeled query (1–5) from `/tmp/sample_queries.sql` into the BigQuery console
individually — keep the tab open for the demo so you can re-run live rather than only
showing static output. The console auto-detects the `@pod_name` parameter in query 4
and prompts you for a value; grab a real one first with
`kubectl --context gke-primary -n apps get pods`.

Don't pipe the whole file into one `bq query --use_legacy_sql=false < ...` call — `bq`
treats multi-statement stdin as a single script (you'd only see the last statement's
result), and query 4 fails outright with an unbound parameter. If you need the CLI
instead of the console, copy one query block at a time into its own file and run
`bq query --use_legacy_sql=false < query.sql` (add `--parameter="pod_name::<pod-name>"`
for query 4).

---

## Step 14. Document the troubleshooting scenario (ongoing) — Deliverable #4

As you work through Steps 1–13, **something will go wrong** — that's expected and is
itself the deliverable. Keep [`docs/TROUBLESHOOTING.md`](TROUBLESHOOTING.md) open and
fill in the real issue you hit (the template lists the likely candidates based on
what's fragile in this stack — MCI propagation delays, Workload Identity binding
typos, Cloud SQL Auth Proxy IAM, quota limits — pick whichever one actually happened
to you and replace the placeholder with the real timeline/fix).

---

## Step 15. Tear-down plan (keep handy, don't run before the demo)

```bash
cd terraform && terraform destroy
```
Note: `terraform destroy` will fail on the Cloud SQL instance if deletion protection
is left on (`deletion_protection = true` is the default in `modules/observability`) —
that's intentional so a stray `destroy` doesn't take out your demo data mid-week; flip
it to `false` only when you're actually done with the exercise.

---

## Demo Checklist (for Tuesday/Wednesday)

- [ ] `kubectl get nodes` on both clusters, live, to show "working cluster"
- [ ] `curl https://$LB_IP/api/catalog` and `/api/orders` — accessible endpoint
- [ ] Grafana dashboard open in a browser tab, all 4 panels populated
- [ ] BigQuery console tab with `sample_queries.sql` ready to run live
- [ ] `docs/TROUBLESHOOTING.md` filled in with your real incident
- [ ] Optional: trigger `kubectl delete pod` on one replica live to show
      self-healing, or scale traffic up live to show HPA + the Grafana dashboard
      reacting in near-real-time — this is the most convincing 60 seconds of the demo

## Production Next Steps (mention, don't build)

Anthos Service Mesh, Cloud SQL cross-region replica/HA, Binary Authorization in
enforced mode, Shared VPC, Managed Prometheus, synthetic uptime checks — see
`DESIGN.md` for why each was scoped out of the Monday timebox and what flipping each
one on would involve.
