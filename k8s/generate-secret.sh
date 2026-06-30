#!/usr/bin/env bash
# Generate the n8n Kubernetes Secret locally. Output (02-secret.yaml) is
# git-ignored and must never be committed.
#
# Reuses N8N_ENCRYPTION_KEY / POSTGRES_PASSWORD from the environment if they are
# already set, otherwise generates fresh random values.
set -euo pipefail
cd "$(dirname "$0")"

ENC_KEY="${N8N_ENCRYPTION_KEY:-$(openssl rand -hex 32)}"
DB_PASS="${POSTGRES_PASSWORD:-$(openssl rand -hex 16)}"

kubectl create secret generic n8n-secret \
  --namespace=n8n \
  --from-literal=N8N_ENCRYPTION_KEY="${ENC_KEY}" \
  --from-literal=DB_POSTGRESDB_PASSWORD="${DB_PASS}" \
  --dry-run=client -o yaml > 02-secret.yaml

echo "Wrote k8s/02-secret.yaml (git-ignored)."
echo "Apply the full stack with:  kubectl apply -k k8s/"
