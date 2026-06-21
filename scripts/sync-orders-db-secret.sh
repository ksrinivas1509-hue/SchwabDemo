#!/usr/bin/env bash
# Pulls the orders-service DB password from Secret Manager (source of truth, written
# by Terraform) and syncs it into a Kubernetes Secret on the given kubectl context.
# Secret Manager stays authoritative; this Secret is just the in-cluster delivery
# mechanism — see docs/DESIGN.md §3 and §7 for why this is a sync script rather than
# the Secret Manager CSI driver for this exercise.
#
# Usage: ./scripts/sync-orders-db-secret.sh <kubectl-context>
set -euo pipefail

CTX="${1:?usage: sync-orders-db-secret.sh <kubectl-context>}"
PROJECT_ID="${PROJECT_ID:?set PROJECT_ID first}"
NAMESPACE="apps"
SECRET_NAME="orders-db-credentials"
DB_USER="orders_app"

PASSWORD="$(gcloud secrets versions access latest \
  --secret=orders-db-password --project="${PROJECT_ID}")"

kubectl --context "${CTX}" -n "${NAMESPACE}" \
  create secret generic "${SECRET_NAME}" \
  --from-literal=username="${DB_USER}" \
  --from-literal=password="${PASSWORD}" \
  --dry-run=client -o yaml | kubectl --context "${CTX}" apply -f -

echo "Synced ${SECRET_NAME} into ${NAMESPACE} on context ${CTX}"
