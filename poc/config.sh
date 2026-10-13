#!/usr/bin/env bash
# Non-secret defaults. Override these with environment variables before running scripts.
POC_SUBSCRIPTION=${POC_SUBSCRIPTION:-a48d0557-360a-4849-8b56-a73b28f66aa6}
POC_LOCATION=${POC_LOCATION:-eastus}
POC_RESOURCE_GROUP=${POC_RESOURCE_GROUP:-rg-aks-github-runners-poc}
POC_CLUSTER=${POC_CLUSTER:-aks-github-runners-poc}
POC_VM_SIZE=${POC_VM_SIZE:-Standard_D4s_v4}
POC_REPOSITORY=${POC_REPOSITORY:-kxw9298/aks-github-runners}
POC_ARC_VERSION=${POC_ARC_VERSION:-0.15.0}
POC_SCALE_SET=${POC_SCALE_SET:-aks-poc-linux}
POC_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
POC_STATE="$POC_ROOT/.poc-state"
export KUBECONFIG="$POC_STATE/kubeconfig"
mkdir -p "$POC_STATE"
chmod 700 "$POC_STATE"
