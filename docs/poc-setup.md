# AKS GitHub runner PoC

This runbook sets up a GitHub App and an ARC runner scale set for the private
`kxw9298/aks-github-runners` repository. The test workflow is started manually.

## Scope and subscription constraints

| Setting | Value |
| --- | --- |
| Azure subscription | `Azure subscription 1` (`a48d0557-360a-4849-8b56-a73b28f66aa6`) |
| Region | `eastus` |
| Resource group | `rg-aks-github-runners-poc` |
| Cluster | `aks-github-runners-poc` |
| Control-plane tier | Free, no production SLA |
| Node pool | One `Standard_D4s_v4` Azure Linux 3 node, named `system` |
| ARC charts | `0.15.0` |
| Runner image | `ghcr.io/actions/actions-runner:2.338.0` |
| Runner scale set | `aks-poc-linux`, minimum 0, maximum 1 |
| Container mode | `kubernetes-novolume`; workflows must specify `container:` |
| GitHub scope | This repository only; personal-account App |

The initial East US regional and Dsv5-family quotas were 4 vCPUs. Requests to
increase each to 12 were submitted, but the regional request failed with
`ResourceNotAvailableForOffer`. `Standard_D4s_v5` was also unavailable for this
subscription in East US; Azure listed `Standard_D4s_v4` as available.

Consequently this first PoC shares one development node between system
components and runners. It can prove App authentication, workflow execution,
ephemeral runners, and **runner-pod** scale-to-zero. It does **not** prove org
isolation or **runner-node** scale-to-zero. The system node remains billable
when runners are idle. AKS production guidance calls for multiple system nodes.
The one-node setup has no node-failure availability and no upgrade surge quota.

This PoC uses a public API endpoint restricted to the setup machine's public
IPv4 address. It does not implement the production design's private API,
firewall, Kata/Docker tier, golden image, or signed-image admission. Keep the
runner restricted to trusted code in this private repository.

## 1. Prerequisites

Install Azure CLI, GitHub CLI, kubectl, Helm 3, Python 3, curl, and OpenSSH.
Authenticate locally:

```bash
az login
gh auth login --hostname github.com
git clone https://github.com/kxw9298/aks-github-runners.git
cd aks-github-runners
az account show --subscription a48d0557-360a-4849-8b56-a73b28f66aa6 -o table
gh auth status
```

The setup identity needs permission to create an AKS cluster, its managed
identity/network resources, and the dedicated resource group. GitHub access
must include repository administration and workflow-file writes.

Scripts put local kubeconfig, SSH keys, and App credentials in `.poc-state/`.
This directory is ignored by Git and is created with mode 700. Credentials
are never committed. Commands pass the subscription explicitly and use a
separate kubeconfig, preserving existing Azure and Kubernetes defaults.

## 2. Register Azure providers and check capacity

```bash
source poc/config.sh
az provider register --subscription "$POC_SUBSCRIPTION" --namespace Microsoft.ContainerService
az provider show --subscription "$POC_SUBSCRIPTION" --namespace Microsoft.ContainerService \
  --query registrationState -o tsv
az vm list-usage --subscription "$POC_SUBSCRIPTION" --location "$POC_LOCATION" -o table
```

Wait for `Registered`. The current shared-node setup consumes 4 regional vCPUs.
If Azure rejects a VM SKU, use the availability list in the error and set
`POC_VM_SIZE` before provisioning. Do not choose a size above the available
quota. The original request IDs and observed deployment state are recorded in
[poc-deployment.md](poc-deployment.md).

## 3. Provision AKS

```bash
bash poc/provision.sh
```

The script creates the tagged dedicated group and one-node cluster with Azure
CNI Overlay/Cilium. It generates a dedicated SSH key, restricts API access to
the client's public IP, and writes `.poc-state/kubeconfig`. AKS creates a
separate managed node resource group for the VM, disk, and network resources.

To override defaults, export `POC_LOCATION`, `POC_SUBSCRIPTION`, `POC_VM_SIZE`, or
`POC_CLIENT_IP` before running. Do not repoint the script to an unrelated
existing cluster. Inspect a failed deployment before rerunning; the script
does not automatically repair an existing failed cluster.

After the client's public IP changes:

```bash
source poc/config.sh
POC_CLIENT_IP=$(curl --fail --silent --show-error https://api.ipify.org)
az aks update --subscription "$POC_SUBSCRIPTION" -g "$POC_RESOURCE_GROUP" \
  -n "$POC_CLUSTER" --api-server-authorized-ip-ranges "$POC_CLIENT_IP/32"
```

## 4. Create and install the GitHub App

Run the local manifest helper:

```bash
python3 poc/register-app.py
```

Open the localhost URL printed by the helper in your signed-in browser. Keep
the helper running until GitHub redirects back after registration. It binds
only to `127.0.0.1` and uses a random state value to protect the callback.
GitHub may require password/verification reauthentication; complete that
directly in the browser.

The manifest requests a private App with these repository permissions:

- **Administration: read and write**, required to register repository runners.
- **Metadata: read**, automatically required by GitHub.
- No organization permissions, code-content permission, or active webhook.

Review the GitHub permission page, then create the App. The helper exchanges
GitHub's one-time manifest code and writes `.poc-state/github-app.pem` and
non-secret metadata `.poc-state/github-app.json`, both with mode 600. It does
not print the key, client secret, or webhook secret.

Follow the installation link. Select the `kxw9298` account and **Only select
repositories → aks-github-runners**. Record the installation ID from the final
installation-settings URL. Stop the helper with Ctrl-C after installation.

If registering manually instead, visit
<https://github.com/settings/apps/new>, choose the same permissions, disable
webhooks, restrict the App to this account, generate a private key, and install
on this repository only. Store the downloaded key outside tracked files.

## 5. Install ARC and the scale set

```bash
export POC_APP_ID=<app-id>
export POC_INSTALLATION_ID=<installation-id>
export POC_APP_KEY_FILE="$PWD/.poc-state/github-app.pem"
bash poc/install-arc.sh
```

The script creates `arc-system` and `arc-runners`, stores the App key in a
Kubernetes Secret, installs the pinned controller chart, and installs the
scale-set chart referencing that Secret. The key is read from a file rather
than passed as literal command-line content or embedded in Helm values.

The runner has the Kubernetes API access needed by container hooks. Generated
job pods disable service-account token mounting through the hook template.
The workflow requires a container, so ordinary workflow steps execute in that
job pod. This is a PoC control, not a complete tenant security boundary.

```bash
source poc/config.sh
kubectl get pods -n arc-system
kubectl get pods -n arc-runners
kubectl get autoscalingrunnersets -n arc-runners
helm list -A
```

Expect the controller and scale-set listener to remain running at idle; there
should be no ephemeral runner pods until a job is assigned.

## 6. Run the smoke test

The workflow file must first exist on the default branch for
`workflow_dispatch` to be available. Then run:

```bash
gh workflow run poc-runner-smoke.yml --repo kxw9298/aks-github-runners --ref main
gh run list --repo kxw9298/aks-github-runners \
  --workflow poc-runner-smoke.yml --limit 5
gh run watch <run-id> --repo kxw9298/aks-github-runners --exit-status
```

The workflow checks out this repository, verifies it is on a self-hosted
runner, runs Node.js in the job container, and verifies a file survives between
steps. Its summary should say `AKS runner smoke test passed`.

Watch pods during execution:

```bash
source poc/config.sh
kubectl get pods -n arc-runners -w
```

Record the dispatch time, runner scheduling time, workflow conclusion, and
the time runner/job pods disappear. Repeat from idle. Completion requires a
successful workflow and confirmation that ephemeral runners return to zero.
Save results in [poc-deployment.md](poc-deployment.md).

## 7. Troubleshooting

- Job stays queued: verify `runs-on: aks-poc-linux`, App installation scope,
  App IDs, controller/listener readiness, and node capacity.
- App authentication fails: inspect App permission and installation settings;
  rotate the key and rerun `install-arc.sh` if necessary.
- Pod remains Pending: inspect `kubectl describe pod` and node requests;
  `maxRunners: 1` intentionally bounds concurrency within the 4-vCPU quota.
- No-volume container job fails: inspect runner and hook logs, verify the
  runner image contains `/home/runner/k8s-novolume/index.js`, and check the
  hook-template mount. Every workflow must specify a job container.
- API connection times out: check the authorized IP against the client's
  current public IPv4 address.

Use `kubectl logs -n arc-system deployment/arc-gha-rs-controller` and
`kubectl logs -n arc-runners <listener-or-runner-pod>` for diagnostics. Avoid
posting raw logs or Secret YAML without checking for credentials.

## 8. Stop costs and tear down

For a temporary pause, stop the cluster after all test jobs finish:

```bash
source poc/config.sh
az aks stop --subscription "$POC_SUBSCRIPTION" -g "$POC_RESOURCE_GROUP" -n "$POC_CLUSTER"
# Resume later:
az aks start --subscription "$POC_SUBSCRIPTION" -g "$POC_RESOURCE_GROUP" -n "$POC_CLUSTER"
```

Stopping the cluster stops node compute; disks and some network resources can
still incur charges. A Free control plane does not make the VMs, disks, public
IP, or egress free. Inspect Cost Management using the dedicated resource group
and its managed node group. No automatic budget shutdown is configured.

To remove the PoC:

```bash
POC_CONFIRM_DELETE=rg-aks-github-runners-poc bash poc/teardown.sh
```

The script unregisters the scale set before deleting Azure resources. If the
cluster is stopped, start it before using the script. Verify both the cluster
and its managed node group are removed. In GitHub, uninstall/delete the App
and confirm no PoC runners remain. Remove local credentials when no longer
needed. Provider registrations and submitted quota requests are subscription
configuration and remain after resource-group deletion.

## 9. Next experiment after quota is available

Create a dedicated autoscaled user pool with minimum 0, maximum 1, an org label
and taint. Move runner and generated job-pod scheduling to that pool while
keeping the controller and listener on system nodes. Check that the first
queued job provisions a node and that the node disappears after the jobs
finish. Reserve additional CPU quota for system-node upgrade surges.

## References

- [GitHub: ARC authentication](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/authenticate-to-the-api)
- [GitHub: register an App from a manifest](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest)
- [GitHub: deploy runner scale sets](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets)
- [Microsoft: AKS system node pools](https://learn.microsoft.com/en-us/azure/aks/use-system-pools)
