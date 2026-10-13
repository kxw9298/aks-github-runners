#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/config.sh"
umask 077
# Use a dedicated key and kubeconfig; do not change the user's existing context.
if [[ ! -f "$POC_STATE/id_rsa" ]]; then
  ssh-keygen -q -t rsa -b 3072 -N '' -f "$POC_STATE/id_rsa"
fi
POC_CLIENT_IP=${POC_CLIENT_IP:-$(curl --fail --silent --show-error https://api.ipify.org)}
python3 - "$POC_CLIENT_IP" <<'PY'
import ipaddress, sys
ipaddress.IPv4Address(sys.argv[1])
PY
az group create --subscription "$POC_SUBSCRIPTION" --name "$POC_RESOURCE_GROUP" \
  --location "$POC_LOCATION" --tags purpose=github-runner-poc owner=kxw9298 --output none
if ! az aks show --subscription "$POC_SUBSCRIPTION" --resource-group "$POC_RESOURCE_GROUP" \
  --name "$POC_CLUSTER" --output none 2>/dev/null; then
  az aks create --subscription "$POC_SUBSCRIPTION" --resource-group "$POC_RESOURCE_GROUP" \
    --name "$POC_CLUSTER" --location "$POC_LOCATION" --tier free \
    --nodepool-name system --node-count 1 --node-vm-size "$POC_VM_SIZE" \
    --node-osdisk-size 64 --node-osdisk-type Managed --os-sku AzureLinux3 \
    --network-plugin azure --network-plugin-mode overlay --network-dataplane cilium \
    --enable-managed-identity --ssh-key-value "$POC_STATE/id_rsa.pub" \
    --api-server-authorized-ip-ranges "$POC_CLIENT_IP/32" \
    --tags purpose=github-runner-poc owner=kxw9298 --output none
fi
POC_CLUSTER_STATE=$(az aks show --subscription "$POC_SUBSCRIPTION" \
  --resource-group "$POC_RESOURCE_GROUP" --name "$POC_CLUSTER" \
  --query provisioningState --output tsv)
if [[ "$POC_CLUSTER_STATE" == Failed ]]; then
  echo 'The existing AKS deployment failed. Inspect its Azure activity log before retrying.' >&2
  exit 1
fi
if [[ "$POC_CLUSTER_STATE" != Succeeded ]]; then
  az aks wait --subscription "$POC_SUBSCRIPTION" --resource-group "$POC_RESOURCE_GROUP" \
    --name "$POC_CLUSTER" --created --interval 30 --timeout 1200
fi
az aks get-credentials --subscription "$POC_SUBSCRIPTION" --resource-group "$POC_RESOURCE_GROUP" \
  --name "$POC_CLUSTER" --file "$KUBECONFIG" --overwrite-existing --output none
chmod 600 "$KUBECONFIG"
kubectl get nodes -o wide
