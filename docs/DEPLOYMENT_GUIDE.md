# Deployment Guide — First-Time GCP Walkthrough (Personal Notes)

This is a beginner-oriented companion to [`IMPLEMENTATION.md`](IMPLEMENTATION.md). That
doc is the terse, copy-pasteable command list (the source of truth — if anything here
ever disagrees with it, trust `IMPLEMENTATION.md`). This doc adds: what each step
actually *is*, why it exists, what success looks like, and what to do if it doesn't
work. Read top to bottom once, then keep `IMPLEMENTATION.md` open in a second tab while
you run commands.

---

## 0. Concepts cheat-sheet (read once)

| Term | What it means here |
|---|---|
| **Project** | The GCP container for everything — like a folder that holds all your cloud resources and is the unit billing attaches to. We have exactly one: `var.project_id`. |
| **Billing account** | The credit card / trial credit GCP charges. Must be linked to a project before that project can create paid resources (a GKE cluster, a Cloud SQL instance, etc.). |
| **API / service** | Each GCP capability (GKE, BigQuery, Cloud SQL...) is a separate "API" that must be explicitly turned on per-project before you can use it. `modules/project` enables the full list we need in one shot. |
| **IAM** | "Who can do what." A *role* (e.g. `roles/container.admin`) is a bundle of permissions; a *binding* says "this person/group/service-account has this role on this project." |
| **Service account (GSA)** | A non-human identity GCP resources use to call other GCP APIs. We have one for the CI/CD pipeline, and one each for `catalog-service`, `orders-service`, and Grafana. |
| **VPC / subnet** | Your private network inside GCP. A VPC is the whole network; subnets are IP-address ranges carved out of it per region/purpose (we have separate subnets for GKE-primary, GKE-secondary, the load balancer, and ops/monitoring). |
| **GKE cluster** | A managed Kubernetes control plane + the machines (nodes) that run your containers. We run two: `gke-primary` (us-central1) and `gke-secondary` (us-east1). |
| **Node pool** | A named group of identically-sized VMs inside a cluster. We have `web-pool` (runs the apps) and `system-pool` (reserved for ingress/system workloads) per cluster. |
| **Pod / Deployment / Service** | Kubernetes basics: a *Pod* is one running copy of a container; a *Deployment* keeps N copies (replicas) of a Pod running and handles rollouts; a *Service* is a stable internal address that load-balances across a Deployment's Pods. |
| **HPA (Horizontal Pod Autoscaler)** | Watches a metric (CPU here) and changes how many replicas a Deployment runs. |
| **Workload Identity** | The mechanism that lets a Kubernetes Pod act as a specific GCP service account *without* a downloaded key file — it maps a Kubernetes ServiceAccount (KSA) to a GCP service account (GSA). |
| **Fleet / Multi-Cluster Ingress (MCI)** | "Fleet" is GCP's grouping of your clusters as a set. MCI is a single global load balancer that routes to whichever cluster in the Fleet is closest/healthy — this is what makes two regional clusters look like one app to the internet. |
| **Terraform `init` / `plan` / `apply`** | `init` downloads the providers/modules; `plan` computes a dry-run diff of what would change; `apply` actually creates/changes/destroys real cloud resources. `apply` is the only one that costs money or is hard to undo. |
| **Terraform state** | A file (`terraform.tfstate`, kept locally here, gitignored) that records what Terraform believes exists in GCP. Don't delete it once you've applied — it's how `destroy` later knows what to clean up. |
| **BigQuery dataset / log sink** | Cloud Logging is configured to continuously export logs into a BigQuery dataset (`logs_export`) so you can run SQL over them. |
| **Helm** | A package manager for Kubernetes — instead of hand-writing Grafana's many YAML files, `helm install` deploys a pre-packaged "chart" with our config layered on top. |

---

## 1. Prerequisites

Required tools, and where each one is used later in this guide:

| Tool | Required for | Install (Homebrew) |
|---|---|---|
| `terraform` >= 1.5 | everything in `terraform/` (§4) | `brew install terraform` |
| `kubectl` | every Kubernetes step (§5, §7, §8, §9, §13, §14) | `brew install kubectl` |
| `gcloud` CLI | auth, project/billing, cluster credentials, image push, Fleet/MCI (§2–§9) | `brew install --cask google-cloud-sdk` |
| `docker` (daemon running) | building app images (§6) — or skip it and use Cloud Build instead | `brew install --cask docker` (Docker Desktop), then launch it |
| `helm` >= 3 | deploying Grafana (§14) | `brew install helm` |
| `mvn` / JDK | **not needed** — both apps build *inside* Docker via a multi-stage `Dockerfile` | — |

One-shot install for whatever's missing:
```bash
brew install terraform kubectl helm
brew install --cask google-cloud-sdk docker
open -a Docker      # starts Docker Desktop so its daemon is running
```

Verify everything is in place before moving on:
```bash
terraform version
kubectl version --client
gcloud version
helm version
docker info >/dev/null 2>&1 && echo "docker daemon OK" || echo "docker daemon NOT running"
```

**Status on this machine, as of 2026-06-20:** all five checks pass — `terraform`
v1.15.6, `kubectl` v1.34.1, `gcloud` 573.0.0, `helm` v4.2.2, and the Docker daemon are
all installed/running. `gcloud` and `helm` were installed via `brew`, and Docker
Desktop's daemon was started, in this session. Nothing left to install before Step 0
below — just `gcloud auth login` (interactive, needs your browser).

---

## 2. Step 0 — Authenticate gcloud & set variables

**What/why:** `gcloud auth login` authenticates *you* (for CLI commands like
`get-credentials`); `application-default login` separately authenticates the libraries
Terraform's Google provider uses — you need both, they're not the same credential.

```bash
gcloud auth login
gcloud auth application-default login
gcloud components install kubectl gke-gcloud-auth-plugin
export USE_GKE_GCLOUD_AUTH_PLUGIN=True   # add this line to ~/.zshrc too, so it survives new terminals

export PROJECT_ID="schwab-gke-demo-$(date +%s | tail -c 6)"   # must be globally unique across all of GCP
export BILLING_ACCOUNT_ID="<your-billing-account-id>"          # get it below
gcloud billing accounts list
```

**✅ Check:** `gcloud auth list` shows your account as `ACTIVE`. `gcloud billing accounts
list` shows at least one account (if you just signed up, this is your free-trial
account).

**⚠️ Cost note:** nothing billable happens until Step 2's `terraform apply`. Once it
does, GCP starts charging your billing account (offset by trial credit if you have it).
Set a budget alert right after the project exists:
```bash
gcloud billing budgets create --billing-account=$BILLING_ACCOUNT_ID \
  --display-name="gke-demo-budget" --budget-amount=50 \
  --threshold-rule=percent=0.5 --threshold-rule=percent=0.9 --threshold-rule=percent=1.0
```

---

## 3. Step 1 — Confirm you can create the project

**What/why:** Terraform creates the GCP project itself in this setup (no manual
`gcloud projects create`). All you do here is confirm your account is allowed to —
true by default for the account that owns a personal/trial billing account.

```bash
gcloud organizations list   # may be empty, may not be — see below
gcloud billing accounts list
```

**✅ Check:** the billing account ID you'll use in Step 2 is visible in that output.
No GCP resources exist yet — this step is read-only.

**Don't assume `organizations list` is empty just because this is a personal account.**
Google now auto-provisions a lightweight Cloud Identity org for some personal Gmail
accounts even though nobody set one up on purpose. If it returns a row, note the `ID`
column — you'll set `org_id` to it in Step 2 (leave `folder_id` null either way; Org →
Project alone already satisfies `instructions` §1's resource-hierarchy ask).

---

## 4. Step 2 — `terraform apply`: the big one

**What/why:** this single command builds almost everything: the project, the network,
both GKE clusters, the Fleet registration, Cloud SQL, Artifact Registry, and the
BigQuery log export. It's the first step that costs money and the first step that's
slow (25–40 minutes, mostly GCP provisioning GKE clusters and Cloud SQL).

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: set project_id, billing_account, and org_id (if Step 1's
# `gcloud organizations list` returned one — leave folder_id null regardless)

export TF_VAR_orders_db_password="$(openssl rand -base64 24)"

terraform init      # downloads the google/google-beta providers — one-time, ~30s
terraform plan -out=tfplan   # dry run: read this output, it lists every resource about to be created
terraform apply tfplan       # the real thing — only step that creates billable resources
```

**✅ Check while waiting:** `terraform plan` output should show roughly 40–60 resources
to add, 0 to change/destroy (it's a brand-new state). During `apply`, Terraform prints
each resource as it finishes — GKE clusters and the Cloud SQL instance are the slowest.

**If it fails partway:** don't panic, just re-run `terraform apply tfplan`. The most
common first-run failure is a just-enabled API not being "warm" yet — see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) §3. It's idempotent — safe to re-run.

**When it finishes:**
```bash
terraform output
```
Keep this terminal/tab open — you'll copy several of these values (`cloudsql_connection_name`,
service-account emails, etc.) into later steps.

---

## 5. Step 3 — Point `kubectl` at your new clusters

**What/why:** `get-credentials` writes connection info into `~/.kube/config`; renaming
the context just gives you short names (`gke-primary`/`gke-secondary`) instead of the
long auto-generated ones.

```bash
gcloud container clusters get-credentials gke-primary   --region us-central1 --project $PROJECT_ID
gcloud container clusters get-credentials gke-secondary  --region us-east1    --project $PROJECT_ID

kubectl config rename-context gke_${PROJECT_ID}_us-central1_gke-primary   gke-primary
kubectl config rename-context gke_${PROJECT_ID}_us-east1_gke-secondary    gke-secondary

kubectl --context gke-primary get nodes
kubectl --context gke-secondary get nodes
```

**If `kubectl` errors with `executable gke-gcloud-auth-plugin not found`**, even after
`gcloud components install gke-gcloud-auth-plugin` (Step 0) succeeds: Homebrew's
`gcloud` cask installs components under `/opt/homebrew/share/google-cloud-sdk/bin`,
which isn't on `PATH` by default. Add it once:
```bash
echo 'export PATH="/opt/homebrew/share/google-cloud-sdk/bin:$PATH"' >> ~/.zshrc
```

**✅ Check:** each `get nodes` lists at least 1 `Ready` node. Don't be surprised if it's
only 1, not 2 — `system-pool` has a `NoSchedule` taint, and GKE's autoscaler only
provisions a pool's first node in response to an actual pod needing to schedule there.
Nothing in this exercise tolerates that taint, so `system-pool` legitimately sits at 0
nodes (a cost-saving side effect, not a bug); `web-pool` gets a node because untainted
system add-ons (kube-dns, etc.) need somewhere to run. Your apps will all land on
`web-pool` regardless.

---

## 6. Step 4 — Build and push the two app images

**What/why:** the apps need to exist as container images in Artifact Registry (GCP's
Docker registry) before Kubernetes can run them. `kustomize edit set image` rewrites
the manifests to point at the image you just pushed instead of a placeholder.

```bash
gcloud auth configure-docker us-central1-docker.pkg.dev

export REPO="us-central1-docker.pkg.dev/${PROJECT_ID}/apps"
export TAG=$(date +%Y%m%d%H%M)

for app in catalog-service orders-service; do
  docker build -t "${REPO}/${app}:${TAG}" "apps/${app}"
  docker push "${REPO}/${app}:${TAG}"
done

(cd ../k8s/base/catalog-service && kustomize edit set image catalog-service="${REPO}/catalog-service:${TAG}")
(cd ../k8s/base/orders-service  && kustomize edit set image orders-service="${REPO}/orders-service:${TAG}")
```
(Run from `terraform/`, hence the `../k8s/...` — adjust if your shell is elsewhere. No
`kustomize` binary? Hand-edit `newTag:`/`newName:` under `images:` in each
`kustomization.yaml` instead.)

**No Docker daemon running?** Use Cloud Build instead — builds in GCP, no local Docker
needed: `gcloud builds submit apps/catalog-service --tag "${REPO}/catalog-service:${TAG}"`
(and again for `orders-service`).

**✅ Check:** `gcloud artifacts docker images list $REPO` shows both images.

---

## 7. Step 5 — Namespaces & Workload Identity sanity check

**What/why:** creates the `apps` namespace (a logical grouping inside each cluster)
that everything else deploys into.

```bash
for ctx in gke-primary gke-secondary; do
  kubectl --context $ctx apply -f k8s/base/namespace/
done

gcloud iam service-accounts get-iam-policy \
  "orders-service-sa@${PROJECT_ID}.iam.gserviceaccount.com"
```

**✅ Check:** the policy output includes `roles/iam.workloadIdentityUser` bound to a
member matching `serviceAccount:${PROJECT_ID}.svc.id.goog[apps/orders-service-sa]` —
this is the GCP half of Workload Identity; the Kubernetes half gets wired in Step 6.

---

## 8. Step 6 — Secrets + deploy the apps

**What/why:** `orders-service` needs a database password, which lives in Secret
Manager (not in Git) and gets synced into a Kubernetes Secret per cluster. Then both
apps deploy, and each gets annotated with its GCP service-account email — that
annotation is the part of Workload Identity that the static YAML can't know ahead of
time (it depends on `$PROJECT_ID`).

```bash
for ctx in gke-primary gke-secondary; do
  ./scripts/sync-orders-db-secret.sh $ctx
done

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
  kubectl --context $ctx -n apps rollout restart deploy/orders-service

  kubectl --context $ctx -n apps rollout status deploy/catalog-service
  kubectl --context $ctx -n apps rollout status deploy/orders-service
done
```

**✅ Check:** both `rollout status` commands print `successfully rolled out`. Then
sanity-check from inside the cluster:
```bash
kubectl --context gke-primary -n apps run curl --rm -it --image=curlimages/curl -- \
  curl -s http://catalog-service/api/catalog
```
You should get back JSON, not a connection error.

**If `orders-service` crash-loops:** almost always a Workload Identity binding typo —
see [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) §2.

---

## 9. Step 7 — Fleet registration & Multi-Cluster Ingress

**What/why:** this is the step that turns "two separate clusters" into "one app with a
single global IP." `fleet ingress enable` turns on the MCI feature; the
`MultiClusterIngress`/`MultiClusterService` objects (applied only to the **config
cluster**, `gke-primary`) describe how traffic should fan out to both clusters.

```bash
gcloud container fleet ingress enable \
  --config-membership=projects/${PROJECT_ID}/locations/global/memberships/gke-primary

gcloud container fleet ingress describe

kubectl --context gke-primary apply -f k8s/base/ingress/
kubectl --context gke-primary -n apps get mcs,mci
```

**This is the slowest step in the whole guide** — the global load balancer (NEGs,
backend services, health checks) takes **10–20 minutes** to provision the first time.
Watch it:
```bash
watch kubectl --context gke-primary -n apps describe mci catalog-ingress
```
**✅ Check:** you're waiting for a `VIP` (an IP address) to appear in the status, and
backend health to turn green. Don't conclude something's broken before ~20 minutes —
this is normal, not a failure.

---

## 10. Step 8 — DNS (optional)

Skip entirely if you don't own a domain — just demo against the raw IP from Step 9.
```bash
export LB_IP=$(kubectl --context gke-primary -n apps get mci catalog-ingress \
  -o jsonpath='{.status.VIP}')
echo $LB_IP
```

---

## 11. Step 9 — Cloud Trace / Profiler (optional, stretch goal)

Skip unless Steps 10–14 below are already solid. See `IMPLEMENTATION.md` Step 9 for
the exact snippet if you have spare time.

---

## 12. Step 10 — Verify the working endpoint (Deliverable #1)

```bash
curl -s "http://${LB_IP}/api/catalog" | jq .
curl -s "http://${LB_IP}/api/orders" | jq .
```
**✅ Check:** both return JSON. Screenshot this — it's literally Deliverable #1
("Working cluster with accessible application endpoint"). **Use `http://`, not
`https://`** — there's no managed TLS cert (no domain to issue one against, see
`docs/DESIGN.md` §9), so the LB only listens on port 80. If you test by typing the
bare IP into a browser address bar instead of pasting the full `http://...` URL, most
browsers auto-upgrade to `https://` by default and will show a connection error —
that's the browser's behavior, not the endpoint actually being down.

---

## 13. Step 11 — Generate demo traffic

**Why:** Grafana and BigQuery need *some* real data before the demo, or every panel
will look empty/boring.

```bash
for i in $(seq 1 200); do
  curl -s "http://${LB_IP}/api/catalog" > /dev/null
  curl -s "http://${LB_IP}/api/catalog/stress?ms=300" > /dev/null
  curl -s -X POST "http://${LB_IP}/api/orders" \
    -H 'Content-Type: application/json' \
    -d '{"product":"widget","quantity":1}' > /dev/null
done
kubectl --context gke-primary -n apps get hpa -w
```
**✅ Check:** watch the HPA's `REPLICAS` column climb as traffic increases — that's
autoscaling working live, good demo moment.

---

## 14. Step 12 — Deploy Grafana (Deliverable #2)

**What/why:** Helm installs Grafana from a published chart; our values file points it
at the BigQuery dataset and Cloud Monitoring, and pre-loads the 4-panel dashboard JSON
so you don't have to build panels by hand.

```bash
helm repo add grafana https://grafana.github.io/helm-charts && helm repo update

kubectl --context gke-primary create namespace monitoring --dry-run=client -o yaml | \
  kubectl --context gke-primary apply -f -

export GRAFANA_SA=$(terraform -chdir=terraform output -raw grafana_sa_email)
envsubst '${PROJECT_ID} ${GRAFANA_SA}' < grafana/helm-values.yaml > /tmp/grafana-values.yaml
# --set-file passes the dashboard JSON through raw, no substitution — it has its own
# ${PROJECT_ID} placeholder (the "Pod restart counts" panel), so envsubst it too:
envsubst '${PROJECT_ID}' < grafana/dashboards/gke-observability.json > /tmp/gke-observability.json

helm upgrade --install grafana grafana/grafana \
  --kube-context gke-primary \
  --namespace monitoring \
  -f /tmp/grafana-values.yaml \
  --set-file 'dashboards.default.gke-observability.json=/tmp/gke-observability.json'

kubectl --context gke-primary -n monitoring get secret grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

```bash
kubectl --context gke-primary -n monitoring port-forward svc/grafana 3000:80
open http://localhost:3000   # log in as admin / the password printed above
```
**✅ Check:** all 4 panels (error rate, pod restarts, latency percentiles, resource
trends) show real data, not "No data." **Screenshot/export this dashboard — Deliverable #2.**

**If a panel says "no data" but the query works in the BigQuery console:** see
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) §4 — usually a missing IAM role on the
Grafana service account.

---

## 15. Step 13 — Run the BigQuery sample queries (Deliverable #3)

```bash
envsubst < bigquery/sample_queries.sql > /tmp/sample_queries.sql
```
Open the BigQuery console, paste each labeled query (1–5) one at a time, and keep the
tab open for the live demo. Query 4 takes a `@pod_name` parameter — grab a real pod
name first with `kubectl --context gke-primary -n apps get pods`.

---

## 16. Step 14 — Document your real troubleshooting issue (Deliverable #4)

Something *will* go wrong while you work through this — that's expected, and is itself
the deliverable. When it does, open [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) and fill
in the "Your Documented Issue" section with what actually happened (not the anticipated
pitfalls list — those are just a diagnosis aid).

---

## 17. Step 15 — Tearing down (don't run before your demo!)

```bash
cd terraform && terraform destroy
```
This will fail on the Cloud SQL instance while `deletion_protection = true` (the
default) — that's deliberate, so a stray `destroy` mid-week can't wipe your demo data.
Flip it to `false` in `modules/observability` only once you're truly done.

**⚠️ Don't forget this step** once the interview is over — two GKE clusters + a Cloud
SQL instance left running will keep burning trial credit/budget.

---

## Quick reference: order of operations

1. Install tools (§1) → 2. `gcloud auth login` + set vars (§2) → 3. confirm project
   creation permission (§3) → 4. `terraform apply` (§4, ☕ 25–40 min) → 5. cluster
   credentials (§5) → 6. build/push images (§6) → 7. namespaces (§7) → 8. secrets +
   deploy apps (§8) → 9. Fleet/MCI (§9, ☕ 10–20 min) → 10. verify endpoint (§12) →
   11. generate traffic (§13) → 12. Grafana (§14) → 13. BigQuery queries (§15) →
   14. fill in troubleshooting doc (§16, ongoing) → 15. tear down after the demo (§17).

## If something looks broken

1. Check [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — it lists the 4 most likely
   failure modes for this exact stack, with fixes.
2. For Terraform errors specifically: re-run `terraform apply tfplan` once — many
   first-run failures are propagation delays, not real bugs.
3. For "is this just slow or actually stuck": MCI (§9) and Cloud SQL/GKE creation (§4)
   are the two genuinely slow steps (10–40 min) — give them time before assuming
   something's wrong.
