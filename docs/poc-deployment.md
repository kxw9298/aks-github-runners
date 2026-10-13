# PoC deployment record

Setup started October 12, 2026 (America/New_York).

## Completed setup work

- Verified local Azure CLI authentication to `Azure subscription 1`.
- Verified GitHub CLI authentication as `kxw9298` and admin access to the private repository.
- Registered `Microsoft.ContainerService` and requested registration of `Microsoft.Quota`.
- Submitted East US regional quota request `f14b0f52-a38a-4eb7-8394-16c242bc0a0a` (4 → 12 vCPUs).
  Azure returned `Failed`, error `ResourceNotAvailableForOffer`.
- Submitted Dsv5-family quota request `de599df5-7cda-4cd5-94e7-73a31e032085` (4 → 12 vCPUs).
  Azure also returned `Failed`, error `ResourceNotAvailableForOffer`.
- Created `rg-aks-github-runners-poc`, tagged `purpose=github-runner-poc`, `owner=kxw9298`.
- First cluster request using `Standard_D4s_v5` failed SKU eligibility validation.
- Retried with one `Standard_D4s_v4` node. Provisioning completed successfully.
  Node `aks-system-43285734-vmss000000` was `Ready` on Kubernetes `v1.35.8`,
  Microsoft Azure Linux 3.0, at approximately 9:26 PM EDT on October 12.
  Managed node resource group: `MC_rg-aks-github-runners-poc_aks-github-runners-poc_eastus`.
- Created `arc-system` and `arc-runners`, plus the job-pod hook ConfigMap.
- Installed ARC controller chart `0.15.0`. Deployment `arc-gha-rs-controller`
  was `1/1` Ready with its pod Running and zero restarts.
- Rendered both ARC 0.15.0 charts locally; checked the controller service-account name,
  no-volume hooks, custom template mount, and runner-image injection.
- GitHub App setup reached the account verification screen; user verification is pending.

## Infrastructure-as-code adoption

The initial Azure CLI / Helm bootstrap has been superseded by two Terraform
stacks in `poc/terraform/`. The imperative provisioning and teardown scripts
were removed. All subsequent Azure and Kubernetes lifecycle changes use
Terraform; Helm charts and values remain the deployment specification for ARC.

- Azure: imported `azurerm_resource_group.poc` and `azurerm_kubernetes_cluster.poc`.
- Kubernetes/Helm: imported both namespaces, the hook ConfigMap, and `helm_release.controller`.
- Provider versions are pinned with committed dependency lock files.
- Adoption applies changed only the load-balancer idle timeout to 30 minutes
  and the Helm provider's recorded repository/values. No resources were created
  or destroyed, and the AKS cluster was not replaced.
- Both final `terraform plan -detailed-exitcode` checks exited 0 with **No changes**.
- Both `terraform validate` checks passed; formatting checks passed.
- After adoption the AKS node remained Ready and the ARC controller remained
  `1/1` Ready, with its original pod Running and zero restarts.
- State and local deployment inputs are ignored by Git. Local state files and
  backups have mode 600. State contains credentials; see the setup guide.
- `enable_runners` remains false pending GitHub account verification and App installation.

## Live runner validation results

| Check | Result |
| --- | --- |
| AKS node Ready | Passed |
| GitHub App created and installed on this repository only | Pending |
| ARC controller Ready | Passed |
| ARC listener Ready | Pending: App installation required |
| Smoke workflow succeeds on AKS | Pending |
| Runner/job pods return to zero | Pending |
| Runner nodes return to zero | Deferred: current shared-node PoC cannot test this |

This file records observed results; configuration alone is not evidence of a
successful live runner test. Update it with the workflow run URL and timestamps
when the test completes. No credentials belong in this file.
