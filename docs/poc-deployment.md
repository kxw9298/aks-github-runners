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
- GitHub App setup initially reached account verification; verification was subsequently completed.

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
- `enable_runners` was subsequently enabled after the App setup recorded below.

## GitHub App and runner scale-set setup

At approximately 9:45 PM EDT on October 12, 2026:

- Created private App `kxw9298-aks-runner-poc`, App ID `5294310`.
- Installed only on `kxw9298/aks-github-runners`, installation ID `170808246`.
- Permissions: repository Administration read/write and Metadata read only.
  Webhooks, OAuth user authorization, and organization permissions are unused.
- Manifest registration initially failed callback-URL validation. The standard
  GitHub form was used with the settings declared in the repository.
- Generated one App key and copied it to ignored `.poc-state/github-app.pem`
  with mode 600. Credential content was not printed or committed.
- Verified the key through App JWT requests to `/app`, the installation, and
  the repository-installation endpoints; all IDs, permissions and selected
  repository scope matched.
- Enabled runners in local Terraform inputs and applied a reviewed plan:
  2 resources added (Kubernetes App Secret and runner Helm release), no other
  resources changed or destroyed.
- Scale set `aks-poc-linux` was `Running`; listener
  `aks-poc-linux-cd5c7bbb-listener` in `arc-system` was `1/1` Ready, Running,
  with zero restarts. There were no runner pods at idle.
- The final ARC Terraform plan exited 0 with **No changes**.
- Workflow execution remains pending: PR #1 is still a draft, and the manually
  dispatched workflow must exist on the default branch before testing.

## Key Vault migration

- Terraform created vault `kvakspoc247fda1b6a`, scoped managed identity
  `id-aks-poc-keyvault`, a federated credential and the setup operator's vault
  role. AKS workload identity was enabled in-place, with no resource replacement.
- Vault: RBAC enabled, purge protection enabled, seven-day soft-delete retention,
  default-deny firewall with only the client/AKS outbound IPs permitted.
- Upgraded Terraform through a workspace-local, checksum-verified 1.16.5 binary
  to use ephemeral inputs and AzureRM write-only secret arguments.
- Uploaded `github-app-credentials` using the credentials Terraform stack.
  Stored App IDs and PEM exactly matched the working credential.
- The reader role is scoped to that one App secret. It is not granted access
  to the rest of the vault.
- Terraform installed External Secrets chart `2.12.0` in `arc-system`, with
  controller access/watch scope limited to `arc-runners`, plus the local
  Key Vault synchronization chart.
- The existing App Secret was removed from Terraform ownership without deletion;
  External Secrets adopted it. SecretStore was Valid/Ready and ExternalSecret
  was SecretSynced/Ready. The runtime PEM exactly matched the vault source.
- A live service-account token exchange proved the workload identity could
  retrieve the App secret (HTTP 200), and received HTTP 403 for both AKS
  recovery-secret names. Credentials were not printed during verification.
- Current ARC/credentials state files contain no App private key. Eight
  obsolete saved plans / key-bearing state backups were removed after verification.
- Final live plans for Azure, credentials and ARC all exited 0 with **No changes**.
- Local working credentials and the browser's PEM download still exist; the
  Azure AKS state still contains admin cluster credentials.
- AKS kubeconfig/SSH vault backups are optional and remain disabled. Automatic
  approval review rejected those extra uploads pending explicit confirmation;
  only the App credential was uploaded.

## Workflow validation results

| Check | Result |
| --- | --- |
| AKS node Ready | Passed |
| GitHub App created and installed on this repository only | Passed |
| ARC controller Ready | Passed |
| ARC listener Ready | Passed |
| Smoke workflow succeeds on AKS | Pending |
| Runner/job pods return to zero | Pending |
| Runner nodes return to zero | Deferred: current shared-node PoC cannot test this |

This file records observed results; configuration alone is not evidence of a
successful live runner test. Update it with the workflow run URL and timestamps
when the test completes. No credentials belong in this file.
