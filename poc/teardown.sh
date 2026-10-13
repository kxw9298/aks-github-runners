#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/config.sh"
# Deliberately restrict deletion to the dedicated PoC group.
[[ "$POC_RESOURCE_GROUP" == rg-aks-github-runners-poc ]] || {
  echo 'Refusing to delete a resource group other than rg-aks-github-runners-poc.' >&2
  exit 1
}
if [[ "${POC_CONFIRM_DELETE:-}" != "$POC_RESOURCE_GROUP" ]]; then
  echo "Set POC_CONFIRM_DELETE=$POC_RESOURCE_GROUP to delete the dedicated PoC resources." >&2
  exit 1
fi
if [[ -f "$KUBECONFIG" ]]; then
  if helm status "$POC_SCALE_SET" --namespace arc-runners >/dev/null 2>&1; then
    helm uninstall "$POC_SCALE_SET" --namespace arc-runners --wait --timeout 5m
  else
    echo 'Scale-set release absent or API unavailable; check GitHub for stale runners after deletion.'
  fi
  if helm status arc --namespace arc-system >/dev/null 2>&1; then
    helm uninstall arc --namespace arc-system --wait --timeout 5m
  fi
fi
az group delete --subscription "$POC_SUBSCRIPTION" --name "$POC_RESOURCE_GROUP" --yes
echo 'Azure PoC resources deleted. Uninstall the GitHub App separately in GitHub settings.'
