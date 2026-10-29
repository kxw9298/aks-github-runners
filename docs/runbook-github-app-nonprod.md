# Runbook: GitHub App for nonprod runners (one org)

_As of Oct 29, 2026_

This runbook sets up the GitHub App that ARC uses to register runners for **one GitHub org in the nonprod cluster**. It also covers key rotation, response to a leaked key, decommissioning and troubleshooting. The design behind it is in [high-level-design.md](high-level-design.md) (runner orchestration, GitHub App credentials, identity and access).

The job-log exporter needs a separate, read-only App. It isn't covered here.

## Roles

| Role | Does |
| --- | --- |
| Org owner, or a member with the GitHub App manager role | Creates the runner group, registers and installs the App, generates its key |
| Platform engineer | Uploads the key to Key Vault, configures ARC, runs the checks |
| Security | Reviews the App's permissions; owns the alerts on App changes |

## Values to fill in

Agree these before starting. Only the private key is secret; the App ID and installation ID aren't, but they're stored with the key.

| Value | Pattern | Example |
| --- | --- | --- |
| GitHub org | `<org>` | `payments` |
| App name | `<prefix>-arc-<org>-nonprod` (unique across GitHub, at most 34 characters) | `acme-arc-payments-nonprod` |
| Runner group | `nonprod-linux` | `nonprod-linux` |
| Scale set name (the `runs-on` label) | `<org>-linux` | `payments-linux` |
| Runner namespace | `arc-<org>` | `arc-payments` |
| Key Vault | The org's nonprod vault | `kv-arc-payments-np` |
| Key Vault secret | `github-app-credentials` | `github-app-credentials` |
| Kubernetes secret synced by External Secrets | `github-app` | `github-app` |

## Before you start

- [ ] The org's nonprod Key Vault exists and meets Step 5a.
- [ ] External Secrets' workload identity has Key Vault Secrets User on the secret `github-app-credentials` only (Step 5b).
- [ ] In the nonprod cluster: the ARC controller and External Secrets Operator are installed, the runner namespace exists, and its SecretStore points at the org's vault.
- [ ] The credentials Terraform stack can write to the vault using write-only arguments, following the same pattern as the PoC ([keyvault-credentials.md](keyvault-credentials.md)).
- [ ] The firewall allows the GitHub endpoints ARC needs ([GitHub docs](https://docs.github.com/en/enterprise-cloud@latest/actions/concepts/runners/communicating-with-self-hosted-runners)).
- [ ] If the org or enterprise uses an IP allow list, the firewall's egress IPs are allowed for this App.
- [ ] Security has agreed the permissions below.

## Step 1: Create the runner group

ARC fails to start the scale set if its runner group doesn't exist, so create the group first.

1. In the org, open **Settings → Actions → Runner groups → New runner group**.
2. Name it `nonprod-linux`.
3. Repository access: **Selected repositories**, then choose the pilot repos.
4. Leave **Allow public repositories** cleared.
5. Workflow access: all workflows. This is fine for nonprod build and test; prod deploy groups are limited to approved workflows.
6. Click **Create group**.

## Step 2: Register the App

Open `https://github.com/organizations/<org>/settings/apps/new` and set:

| Field | Value |
| --- | --- |
| GitHub App name | `<prefix>-arc-<org>-nonprod` |
| Description | `ARC runner registration for <org>, nonprod cluster` |
| Homepage URL | The internal page or repo for the runner platform |
| Callback URL | Leave empty |
| Request user authorization (OAuth) during installation | Off |
| Enable Device Flow | Off |
| Setup URL | Leave empty |
| Webhook | Clear **Active** (ARC doesn't use webhooks) |
| Repository permissions | **Metadata: Read-only** (added automatically); leave everything else as No access |
| Organization permissions | **Self-hosted runners: Read and write**; leave everything else as No access |
| Account permissions | None |
| Subscribe to events | None |
| Where can this GitHub App be installed? | **Only on this account** |

Click **Create GitHub App** and write down the **App ID** from the App's settings page.

## Step 3: Generate the private key

1. On the App's settings page, under **Private keys**, click **Generate a private key**. The browser downloads a `.pem` file.
2. Don't email the file, paste it into chat or a ticket, or commit it. Keep it only until Step 5 is done.

## Step 4: Install the App on the org

1. On the App's page, click **Install App**, then **Install** next to the org.
2. Repository access: **Only select repositories**, then choose the pilot repos. The App has no repository permissions beyond Metadata, so this only limits what it can see.
3. Click **Install**.
4. Write down the **installation ID**: the number at the end of the URL, `/organizations/<org>/settings/installations/<id>`.

## Step 5: Store the credentials in Key Vault

Key Vault is the only place the private key lives. Kubernetes gets a synced copy, and nobody keeps one locally.

### 5a. Check the vault

The org's nonprod vault must have:

| Setting | Value |
| --- | --- |
| Permission model | Azure RBAC (no access policies) |
| Soft delete and purge protection | On, with 90-day retention |
| Network | Public network access disabled; private endpoint in the nonprod spoke, with a private DNS zone |
| Diagnostic settings | `AuditEvent` logs to Event Hubs, so every secret read and write reaches the SOC |
| Scope | This org and this environment only; prod keys go in the prod vault |

### 5b. Access to the secret

| Who | Role | Scope | How |
| --- | --- | --- | --- |
| Platform engineer uploading the key | Key Vault Secrets Officer | The vault | PIM, for the length of the task |
| External Secrets in `arc-<org>` | Key Vault Secrets User | The secret `github-app-credentials` only, not the whole vault | Workload identity federated to `system:serviceaccount:arc-<org>:keyvault-reader` |
| Everyone else | None | | |

The runner pods have no Azure identity, so they can't read the vault.

### 5c. Secret format

One secret, `github-app-credentials`, whose value is JSON with exactly these fields:

```json
{
  "github_app_id": "<App ID>",
  "github_app_installation_id": "<installation ID>",
  "github_app_private_key": "<contents of the .pem file, newlines included>"
}
```

Set these properties on it:

| Property | Value |
| --- | --- |
| Content type | `application/json` |
| Expiration date | 90 days from upload, which matches the rotation schedule |
| Tags | `org=<org>`, `env=nonprod`, `app-id=<App ID>`, `owner=platform-runners` (no secrets in tags) |

### 5d. Upload it

**Preferred: Terraform with write-only arguments.** Use the credentials stack, as in the PoC ([keyvault-credentials.md](keyvault-credentials.md)). `azurerm_key_vault_secret` takes the value through `value_wo`, which isn't stored in plans or state, and `value_wo_version` changes on each rotation. A wrapper supplies the value through an environment variable, so it never appears on a command line.

**Fallback, if the stack isn't ready yet: Azure CLI reading from a file.**

```bash
umask 077
# Build the JSON in a file that only you can read; don't echo it to the terminal.
az keyvault secret set \
  --vault-name <vault> --name github-app-credentials \
  --file ./github-app-credentials.json --encoding utf-8 \
  --content-type application/json \
  --expires <YYYY-MM-DDT00:00:00Z> \
  --tags org=<org> env=nonprod app-id=<App ID> owner=platform-runners \
  --query id -o tsv
shred -u ./github-app-credentials.json
```

Never pass the key with `--value`, because it would land in shell history and process lists.

### 5e. Check it, without reading the value

```bash
az keyvault secret show --vault-name <vault> --name github-app-credentials \
  --query "{enabled:attributes.enabled, expires:attributes.expires, contentType:contentType}"
kubectl get externalsecret github-app -n arc-<org>    # SecretSynced, Ready
```

Then:

1. Delete the downloaded `.pem` file, and empty the trash or recycle bin.
2. Confirm that no copy is left in Downloads, chat, tickets or the repo.

External Secrets syncs the vault secret into the Kubernetes secret `github-app` in the runner namespace, refreshing every minute.

The design's alternative is ARC's built-in Key Vault mode, which reads the secret directly so no copy sits in the runner namespace ([GitHub App credentials](high-level-design.md#github-app-credentials)). In ARC 0.15.0 it authenticates only with a client certificate, so External Secrets is the default.

## Step 6: Configure the scale set

Set these in the org's scale set Helm values, which Terraform manages:

```yaml
githubConfigUrl: https://github.com/<org>
githubConfigSecret: github-app
runnerGroup: nonprod-linux
runnerScaleSetName: <org>-linux
minRunners: 0
maxRunners: 10        # per the org's capacity cap
containerMode:
  type: kubernetes-novolume
```

The node selector, toleration and security context come from the org's template, as described in the design. Apply the reviewed Terraform plan.

## Step 7: Verify

Run these checks without printing secret contents:

```bash
kubectl get secretstore,externalsecret -n arc-<org>      # both Ready / SecretSynced
kubectl get secret github-app -n arc-<org>               # exists; don't decode it
kubectl get autoscalingrunnersets -n arc-<org>           # scale set present
kubectl get pods -n arc-system | grep <org>-linux        # listener Running, no restarts
```

In GitHub, **Settings → Actions → Runner groups → nonprod-linux** should list the `<org>-linux` scale set.

Then run a smoke workflow from a pilot repo:

```yaml
name: arc-smoke
on: workflow_dispatch
permissions:
  contents: read
jobs:
  smoke:
    runs-on: <org>-linux
    container:
      image: <platform-acr>.azurecr.io/<job-image>@sha256:<digest>
    steps:
      - uses: actions/checkout@<commit-sha>
      - run: echo "runner=$RUNNER_NAME environment=$RUNNER_ENVIRONMENT"
```

The pass criteria:

- [ ] The job starts on an `<org>-linux` runner and succeeds.
- [ ] Its pods run on the org's node pool.
- [ ] After the job, the runner namespace has no runner pods.
- [ ] The run shows up in Dynatrace, if the log pipeline is already in place.
- [ ] Before the pilot, the SIEM alerts on changes to this App's permissions or installation, and on any read of `github-app-credentials` by an identity other than External Secrets'.
- [ ] An alert fires 14 days before the secret's expiration date.

## Rotate the key

Rotate on a fixed schedule, for example every 90 days, and whenever someone who handled the key leaves.

1. Generate a new private key on the App's settings page. The old key keeps working until you delete it.
2. Upload the new key to `github-app-credentials` as a new version, with a new expiration date (Step 5d). With the PoC stack, that means incrementing `credential_revision`.
3. Wait for External Secrets to sync, which takes about a minute. If the listener doesn't pick up the change, restart it through the ARC controller.
4. Run the smoke workflow.
5. Delete the old key in GitHub, then delete the downloaded file.

## If the key leaks

1. **Revoke the key:** delete it on the App's settings page. If you can't tell which key leaked, delete all of them, or suspend the installation under **Settings → GitHub Apps → Configure → Suspend**.
2. **Stop the runners:** set the scale set's `minRunners` and `maxRunners` to 0.
3. **Find rogue runners:**
   - Check the org's runners and runner groups for anything that isn't an ARC runner from this scale set, and remove it.
   - Search the audit log for runner registrations and App events since the leak.
4. **Issue a new key:** follow Step 3 and Step 5, then unsuspend the installation and restore the scale set.
5. **Review:** with security, check the firewall, Key Vault and Kubernetes audit logs for how the key was taken. Follow the quarantine runbook in the design if a runner pod was involved.

## Decommission

1. Set the scale set to 0, then remove it through Terraform.
2. Uninstall the App from the org, then delete the App from **Settings → Developer settings → GitHub Apps**.
3. Delete `github-app-credentials` from the vault. It stays soft-deleted for the vault's retention period.
4. Delete the runner group if nothing else uses it.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Listener crash-loops with `401 Bad credentials` | Wrong App ID or installation ID, a malformed PEM, or a deleted key | Check the three JSON fields and upload a new version |
| `403 Resource not accessible by integration` | The App lacks **Self-hosted runners: Read and write**, or the org owner hasn't accepted a permission change | Fix the permission; the org owner accepts the update under the installation's settings |
| ARC reports the runner group isn't found | The group is missing or named differently | Create it, or fix `runnerGroup` |
| Jobs stay queued | The `runs-on` label doesn't match `runnerScaleSetName`; the repo isn't in the runner group; the installation is suspended; or the listener isn't ready | Check each one in that order |
| Jobs fail because a job container is required | The workflow has no `container:` | Add a job container from the platform ACR |
| ExternalSecret isn't synced | Workload identity, the Key Vault role assignment, or the vault's network access | Check the SecretStore status and the identity's role on the secret |

## References

- [Authenticating ARC to the GitHub API](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/authenticate-to-the-api) (GitHub Docs)
- [Deploying runner scale sets](https://docs.github.com/en/actions/how-tos/manage-runners/use-actions-runner-controller/deploy-runner-scale-sets) (GitHub Docs)
- [Registering a GitHub App](https://docs.github.com/en/enterprise-cloud@latest/apps/creating-github-apps/registering-a-github-app/registering-a-github-app) (GitHub Docs)
- [Managing private keys for GitHub Apps](https://docs.github.com/en/enterprise-cloud@latest/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps) (GitHub Docs)
- [Managing access to self-hosted runners using groups](https://docs.github.com/en/enterprise-cloud@latest/actions/how-tos/manage-runners/self-hosted-runners/manage-access) (GitHub Docs)
- [az keyvault secret set](https://learn.microsoft.com/en-us/cli/azure/keyvault/secret#az-keyvault-secret-set) (Microsoft Learn)
- [Azure Key Vault soft-delete overview](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview) (Microsoft Learn)
- [Terraform write-only arguments](https://developer.hashicorp.com/terraform/language/manage-sensitive-data/write-only) (HashiCorp)
- [External Secrets Azure Key Vault provider](https://external-secrets.io/latest/provider/azure-key-vault/) (External Secrets)
