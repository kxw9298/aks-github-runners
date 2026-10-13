#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/config.sh"
: "${POC_APP_ID:?Set POC_APP_ID to the GitHub App ID}"
: "${POC_INSTALLATION_ID:?Set POC_INSTALLATION_ID to the repository installation ID}"
: "${POC_APP_KEY_FILE:?Set POC_APP_KEY_FILE to the local PEM file path}"
[[ -r "$POC_APP_KEY_FILE" ]] || { echo 'Cannot read the GitHub App key file.' >&2; exit 1; }
kubectl create namespace arc-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace arc-runners --dry-run=client -o yaml | kubectl apply -f -
# Key content is read from a file, never placed in command arguments or Helm values.
kubectl create secret generic github-app --namespace arc-runners \
  --from-literal=github_app_id="$POC_APP_ID" \
  --from-literal=github_app_installation_id="$POC_INSTALLATION_ID" \
  --from-file=github_app_private_key="$POC_APP_KEY_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$POC_ROOT/poc/hook-template.yaml"
helm upgrade --install arc \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  --version "$POC_ARC_VERSION" --namespace arc-system \
  --values "$POC_ROOT/poc/controller-values.yaml" --wait --timeout 5m
helm upgrade --install "$POC_SCALE_SET" \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  --version "$POC_ARC_VERSION" --namespace arc-runners \
  --values "$POC_ROOT/poc/runner-values.yaml" \
  --set-string githubConfigUrl="https://github.com/$POC_REPOSITORY" \
  --set-string runnerScaleSetName="$POC_SCALE_SET" --wait --timeout 5m
kubectl get pods -n arc-system
kubectl get pods -n arc-runners
