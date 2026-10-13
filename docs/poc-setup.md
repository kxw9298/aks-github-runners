# AKS GitHub runner PoC — infrastructure as code

All Azure and Kubernetes infrastructure is declared in Terraform. ARC uses
Terraform-managed Helm releases with version-controlled values. Use Terraform
for provisioning, changes, imports, and teardown; do not create or modify the
resources with Azure CLI, kubectl apply, or direct Helm install commands.

## Layout

| Path | Managed objects |
| --- | --- |
| `poc/terraform/azure/` | Resource group, AKS cluster, system pool, managed identity, API access, network configuration, tags |
| `poc/terraform/arc/` | Namespaces, hook ConfigMap, GitHub App Secret, controller and runner Helm releases |
| `poc/*-values.yaml` | Pinned Helm deployment configuration |
| `poc/hook-template.yaml` | Source for the Terraform-managed job-pod ConfigMap |
| `poc/github-app-manifest.json` | Declarative GitHub App permissions and registration settings |
| `.github/workflows/poc-runner-smoke.yml` | Manually triggered runner test |

The two Terraform stacks have separate state. Apply Azure first, then ARC;
destroy ARC first, then Azure. This avoids configuring Kubernetes providers
against a cluster that does not exist yet. AKS owns the VM, disk, load balancer,
and network resources in its managed node resource group as children of the
Terraform-managed cluster; do not separately manage those child resources.

## Current PoC settings

| Setting | Value |
| --- | --- |
| Subscription | `Azure subscription 1` (`a48d0557-360a-4849-8b56-a73b28f66aa6`) |
| Region | `eastus` |
| Resource group | `rg-aks-github-runners-poc` |
| Cluster | `aks-github-runners-poc` |
| Tier | Free control plane, no production SLA |
| Node pool | One `Standard_D4s_v4` Azure Linux 3 node, named `system` |
| Kubernetes | `1.35` (observed patch `1.35.8`) |
| ARC charts / runner image | `0.15.0` / `2.338.0` |
| Scale set | `aks-poc-linux`, minimum 0, maximum 1 |
| Container mode | `kubernetes-novolume`; jobs require `container:` |
| GitHub scope | Private repository `kxw9298/aks-github-runners` only |

East US has a 4-vCPU regional quota. Both requests for 12 vCPUs failed with
`ResourceNotAvailableForOffer`. `Standard_D4s_v5` was unavailable to this
subscription; `Standard_D4s_v4` succeeded. The shared one-node development
setup tests App authentication, ephemeral runners and runner-pod scale-to-zero.
It cannot prove org isolation or runner-node scale-to-zero, and has no node
failure availability or spare upgrade-surge capacity.

The public API endpoint permits only the setup client's public IPv4 CIDR.
Private API access, firewall, Kata/Docker, golden images and signed-image
admission remain later experiments. Use trusted code in this private repo.

## 1. Prepare local tools and inputs

Required: Terraform 1.5+, Azure CLI, GitHub CLI, kubectl, Python 3 and OpenSSH.
The provider versions and provider lock files are committed. Helm CLI is useful
for read-only diagnosis; Terraform owns the Helm release lifecycle.

```bash
az login
gh auth login --hostname github.com
git clone https://github.com/kxw9298/aks-github-runners.git
cd aks-github-runners
umask 077
mkdir -p .poc-state
chmod 700 .poc-state
# For a new deployment only; keep the existing key when adopting a cluster:
ssh-keygen -t rsa -b 3072 -N '' -f .poc-state/id_rsa
cp poc/terraform/azure/terraform.tfvars.example poc/terraform/azure/terraform.tfvars
```

Edit the copied `.tfvars`: set the allowed public IPv4 CIDR and subscription.
For an existing cluster, preserve its deployed DNS prefix and SSH public key;
changing immutable fields can cause replacement. The example prefix is suitable
for a new cluster. The current imported cluster has prefix
`aks-github-rg-aks-github-ru-a48d05`.

Do not create `.tfvars` if the local adoption inputs `terraform.tfvars.json`
already exist: Terraform reads both files and duplicate variable definitions
are confusing. The setup machine already has those ignored JSON inputs.

Provider `resource_provider_registrations = "core"` handles the Azure resource
provider bootstrap. The setup identity needs permission for provider
registration and the resource group, AKS and its managed resources.

## 2. Apply Azure infrastructure

For a new deployment:

```bash
terraform -chdir=poc/terraform/azure init
terraform -chdir=poc/terraform/azure validate
terraform -chdir=poc/terraform/azure plan -out=azure.tfplan
terraform -chdir=poc/terraform/azure apply azure.tfplan
```

For the currently deployed cluster, import instead of creating it. These
imports have already been performed on the setup machine; do not repeat them
against an existing state:

```bash
terraform -chdir=poc/terraform/azure import azurerm_resource_group.poc \
  /subscriptions/a48d0557-360a-4849-8b56-a73b28f66aa6/resourceGroups/rg-aks-github-runners-poc
terraform -chdir=poc/terraform/azure import azurerm_kubernetes_cluster.poc \
  /subscriptions/a48d0557-360a-4849-8b56-a73b28f66aa6/resourceGroups/rg-aks-github-runners-poc/providers/Microsoft.ContainerService/managedClusters/aks-github-runners-poc
terraform -chdir=poc/terraform/azure plan
```

Review any change before applying, particularly resource replacement. The
initial adoption normalized the load-balancer idle timeout to the declared
30 minutes without recreating the cluster.

Fetch credentials after Azure is ready. This command only establishes local
access; it does not deploy infrastructure or change the cluster:

```bash
az aks get-credentials --subscription a48d0557-360a-4849-8b56-a73b28f66aa6 \
  --resource-group rg-aks-github-runners-poc --name aks-github-runners-poc \
  --file "$PWD/.poc-state/kubeconfig" --overwrite-existing
chmod 600 .poc-state/kubeconfig
export KUBECONFIG="$PWD/.poc-state/kubeconfig"
kubectl get nodes -o wide
```

If the client's public IP changes, edit `authorized_ip_ranges` in the Azure
Terraform inputs and apply the reviewed plan. Do not use `az aks update` to
change the allowlist independently of Terraform.

## 3. Apply the controller stack

```bash
cp poc/terraform/arc/terraform.tfvars.example poc/terraform/arc/terraform.tfvars
terraform -chdir=poc/terraform/arc init
terraform -chdir=poc/terraform/arc validate
terraform -chdir=poc/terraform/arc plan -out=arc.tfplan
terraform -chdir=poc/terraform/arc apply arc.tfplan
```

Again, use existing local `.tfvars.json` inputs instead of copying a second
input file on the setup machine. Leave `enable_runners = false` until the App
is installed. This deploys the controller, two namespaces and hook ConfigMap.

The existing objects were adopted with these Terraform imports:

```bash
terraform -chdir=poc/terraform/arc import kubernetes_namespace_v1.system arc-system
terraform -chdir=poc/terraform/arc import kubernetes_namespace_v1.runners arc-runners
terraform -chdir=poc/terraform/arc import kubernetes_config_map_v1.hook arc-runners/runner-hook-template
terraform -chdir=poc/terraform/arc import helm_release.controller arc-system/arc
```

The adoption apply records the installed Helm chart repository and values in
Terraform. There is no separate direct Helm deployment path.

## 4. Register and install the GitHub App

GitHub App registration is an account bootstrap requiring interactive account
verification and installation approval. Its required permissions are declared
in `poc/github-app-manifest.json`. The standard GitHub form below is the path
used and verified for this PoC.

1. Open <https://github.com/settings/apps/new> in the signed-in browser.
   Complete any account verification directly in GitHub.
2. Name the App `kxw9298-aks-runner-poc`. Set Homepage URL to
   `https://github.com/kxw9298/aks-github-runners`.
3. Leave OAuth user authorization, device flow and redirect URIs unused.
   Under Webhook, clear **Active**; ARC does not require a webhook endpoint.
4. Expand Repository permissions. Set **Administration → Read and write**.
   GitHub automatically adds **Metadata → Read-only**. Leave other repository,
   organization, account and enterprise permissions unset.
5. Choose **Only on this account**, then **Create GitHub App**.
6. Record the App ID. Open **Credentials → Key pairs → New key** (or the
   **generate a private key** link). GitHub downloads the PEM key.
7. Open **Install App**, choose the `kxw9298` account, and select **Only select
   repositories → aks-github-runners**. Verify one repository is selected,
   then install. Record the installation ID from the resulting settings URL.
8. Copy the downloaded key to `.poc-state/github-app.pem` with mode 600.
   Do not print the key, commit it, or paste it into chat or a command argument.

The verified App has ID `5294310`; its repository-only installation is
`170808246`. Its settings are at
<https://github.com/settings/apps/kxw9298-aks-runner-poc> and installation scope
at <https://github.com/settings/installations/170808246>. The App JWT was tested
against GitHub's `/app`, installation, and repository-installation endpoints:
all returned the expected IDs and Administration/Metadata permissions.

An optional manifest helper is included in `poc/register-app.py`. It binds only
to loopback, submits the checked-in manifest, and exchanges the callback code
without logging credentials. The initial callback URL was rejected by GitHub,
so this live deployment used the standard form above. The helper was corrected
to pass CSRF state on GitHub's registration URL rather than inside the callback
URL, following GitHub's documented flow; that corrected registration path has
not been tested by creating another App. Use the verified form for this PoC.

## 5. Enable the runner scale set through Terraform

Edit the ARC stack's ignored inputs:

```hcl
enable_runners             = true
github_app_id              = "YOUR_APP_ID"
github_app_installation_id = "YOUR_INSTALLATION_ID"
github_app_private_key_file = "../../../.poc-state/github-app.pem"
```

```bash
terraform -chdir=poc/terraform/arc plan -out=runners.tfplan
terraform -chdir=poc/terraform/arc apply runners.tfplan
kubectl get pods -n arc-system
kubectl get pods -n arc-runners
```

Terraform creates the Kubernetes Secret and the runner Helm release. Helm
references the Secret; the key is not placed in literal shell arguments or
version-controlled values. Generated job pods disable service-account token
mounting through the hook template. Job containers are mandatory.

## State and credential handling

This PoC currently uses separate **local** Terraform state files. Azure state
contains cluster credentials; ARC state contains the App key after runners
are enabled. `sensitive()` hides values from normal Terraform output but does
not encrypt state. State, backups, saved plans, `.terraform/`, local `.tfvars`,
kubeconfig and PEM files are ignored by Git. Run with `umask 077` and retain a
secure backup of both state files; losing them loses Terraform ownership.
For team or unattended use, migrate to a secured remote backend before sharing
access. Never commit or attach state or saved plan files to a PR.

## 6. Test the runner

The workflow must exist on the default branch for manual dispatch:

```bash
gh workflow run poc-runner-smoke.yml --repo kxw9298/aks-github-runners --ref main
gh run list --repo kxw9298/aks-github-runners --workflow poc-runner-smoke.yml --limit 5
gh run watch <run-id> --repo kxw9298/aks-github-runners --exit-status
kubectl get pods -n arc-runners -w
```

The test checks out this repository, verifies self-hosted execution, runs
Node.js in the job container, and checks a file persists across steps. The
summary should report `AKS runner smoke test passed`. Record the run URL,
startup latency, and confirmation that runner/job pods disappear after the job
in [poc-deployment.md](poc-deployment.md). Repeat from idle. Controller and
listener pods remain running. The single shared node also remains running.

Read-only diagnosis:

```bash
kubectl get autoscalingrunnersets -n arc-runners
kubectl describe pod -n arc-runners <pod>
kubectl logs -n arc-system deployment/arc-gha-rs-controller
kubectl logs -n arc-runners <listener-or-runner-pod>
```

Queued jobs usually indicate App scope/credentials, the runner label, listener
readiness, or capacity. Pending pods require checking scheduling and requests.
Check the API allowlist if local Kubernetes access times out. Review logs for
credentials before sharing them.

## 7. Teardown through IaC

After all jobs finish, destroy the ARC stack first while Kubernetes is
reachable, then the Azure stack:

```bash
terraform -chdir=poc/terraform/arc plan -destroy -out=destroy-arc.tfplan
terraform -chdir=poc/terraform/arc apply destroy-arc.tfplan
terraform -chdir=poc/terraform/azure plan -destroy -out=destroy-azure.tfplan
terraform -chdir=poc/terraform/azure apply destroy-azure.tfplan
```

Review each destruction plan to confirm it targets only this PoC. Terraform's
ARC dependencies remove the runner release before its Secret, namespace,
controller and hook ConfigMap. AKS deletion also removes its managed node
resources. Uninstall/delete the App in GitHub and confirm no PoC runners
remain; account App registration is outside Terraform's Azure/Kubernetes state.
Subscription provider registrations and historic quota requests remain.

Free control-plane tier does not make the VM, disk, public IP or egress free.
The node stays billable at idle until teardown; no budget shutdown is configured.

## Next experiment

After quota is available, add a Terraform-managed autoscaled user pool with
minimum 0 and maximum 1. Change the checked-in runner and hook scheduling to
its labels/taints, preserving controller/listener placement on system nodes.
Then verify node scale-from-zero and scale-to-zero. Budget quota for system-node
upgrade surges and multiple system nodes before production use.

## References

- [AzureRM AKS resource](https://registry.terraform.io/providers/hashicorp/azurerm/4.76.0/docs/resources/kubernetes_cluster)
- [Helm release resource](https://registry.terraform.io/providers/hashicorp/helm/2.17.0/docs/resources/release)
- [GitHub App manifest registration](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest)
- [GitHub ARC authentication](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/authenticate-to-the-api)
