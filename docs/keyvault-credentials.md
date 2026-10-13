# Key Vault credential management

Azure Key Vault is the source of truth for the PoC credentials. Infrastructure
and secret synchronization are declared in Terraform and Helm. The private
values use Terraform 1.11+ ephemeral variables and AzureRM `value_wo` arguments,
so the credentials stack does not persist those values in plans or state.

The deployed vault is `kvakspoc247fda1b6a` in `rg-aks-github-runners-poc`.
The App credential is migrated and synchronization is verified. Optional AKS
recovery credentials are not uploaded: explicit approval for those additional
credential payloads is pending, so their configuration remains disabled.

## Stored credentials and access

| Vault secret | Contents | Runtime access |
| --- | --- | --- |
| `github-app-credentials` | JSON: App ID, installation ID, PEM private key | Dedicated workload identity, restricted to this secret |
| `aks-kubeconfig` (optional; disabled by default) | Base64-encoded local admin kubeconfig, for recovery | Setup operator only |
| `aks-ssh-private-key` (optional; disabled by default) | Base64-encoded PoC SSH private key, for recovery | Setup operator only |

The vault has Azure RBAC, purge protection, seven-day soft-delete retention,
and a default-deny firewall allowing only the setup client's approved IP and
AKS's managed outbound IP. It uses a restricted public endpoint for this PoC.
The setup identity has Key Vault Secrets Officer at vault scope. The runtime
identity has Key Vault Secrets User only at the App secret's scope; it cannot
read the admin kubeconfig or SSH backup.

The identity federates only the AKS service-account subject
`system:serviceaccount:arc-runners:keyvault-reader`. No Azure client secret or
certificate is needed for runtime authentication. External Secrets Operator
uses this referenced service account, watches only `arc-runners`, and has
namespace-scoped secret access. Its Helm deployment lives in `arc-system`.

## Deployment order

Use Terraform 1.11 or newer. The setup machine has a checksum-verified
workspace-local Terraform at `.poc-state/bin/terraform`; its global older
installation is unchanged. Set `POC_TERRAFORM` to a suitable binary if needed.

1. **Azure stack**: apply `poc/terraform/azure`. This creates the vault and
   identity, enables AKS workload identity, and creates the federated credential.
2. **Credentials stack**: initialize `poc/terraform/credentials`, populate its
   ignored input file with subscription ID, vault resource ID and reader
   principal ID from the Azure stack outputs, then upload through the wrapper.
3. **ARC stack**: set `key_vault_uri`, `vault_reader_client_id` and `tenant_id`
   from Azure outputs. Apply `poc/terraform/arc` after the credential upload and
   secret-scoped reader role assignment succeed.

```bash
umask 077
export POC_TERRAFORM="$PWD/.poc-state/bin/terraform"
"$POC_TERRAFORM" -chdir=poc/terraform/azure plan -out=keyvault.tfplan
"$POC_TERRAFORM" -chdir=poc/terraform/azure apply keyvault.tfplan
"$POC_TERRAFORM" -chdir=poc/terraform/credentials init
python3 poc/manage-credentials.py plan -out=credentials.tfplan
python3 poc/manage-credentials.py apply credentials.tfplan
"$POC_TERRAFORM" -chdir=poc/terraform/arc plan -out=keyvault-sync.tfplan
"$POC_TERRAFORM" -chdir=poc/terraform/arc apply keyvault-sync.tfplan
```

`manage-credentials.py` reads the existing local App key and metadata, supplies
the values transiently through `TF_VAR_secret_values`,
and runs Terraform without printing them or putting them in command arguments.
It requires debug logging to be disabled. Saved plans exclude ephemeral input
values, and write-only provider arguments omit values from resource state.
The kubeconfig and SSH key are read/uploaded only when
`include_aks_recovery_credentials = true` is explicitly enabled in the ignored
credentials `terraform.tfvars.json`, after approval to store those credentials
in this vault. The current PoC leaves this setting false. Continue protecting
state because the Azure AKS resource itself still contains
admin cluster credentials.

For a fresh deployment, the same sequence applies. Do not use `terraform init`
or `plan` with an older binary for the credentials/ARC stacks. The required
Terraform version is declared in those stacks.

## Runtime synchronization and migration

The Terraform-managed local chart in `poc/charts/keyvault-sync` creates a
namespaced SecretStore and ExternalSecret. It extracts the App credential JSON
from Key Vault into Kubernetes Secret `github-app` in `arc-runners`, refreshing
every minute. ARC references that Secret as before. A Kubernetes copy remains
necessary for this integration; Key Vault replaces local files and Terraform
state as its authoritative runtime source.

During migration, the Terraform `removed` block relinquishes ownership of the
existing Secret **without deleting it**. External Secrets adopts it. The App key
is no longer an input to the ARC Terraform stack, and that stack no longer
reads or owns the secret data. Historical state backups and saved plans from
before migration can still contain the key and must be removed after the vault
and synchronization have been verified. Eight obsolete saved plans / key-bearing
state backups were removed after successful verification. The PoC keeps the local working key,
kubeconfig and SSH files protected and ignored by Git; moving credentials into
the vault does not automatically delete those working files or the browser's
original PEM download.

Validate without printing secret contents:

```bash
export KUBECONFIG="$PWD/.poc-state/kubeconfig"
kubectl get secretstore,externalsecret -n arc-runners
kubectl get pods -n arc-system
kubectl get secret github-app -n arc-runners
"$POC_TERRAFORM" -chdir=poc/terraform/arc plan -detailed-exitcode
```

Expect SecretStore/ExternalSecret Ready, the ARC listener Ready, and no
Terraform drift. Never decode the Secret into terminal output during checks.

## Rotation and recovery

Generate a replacement App key in GitHub, update the local working PEM, and
increment `credential_revision` in the credentials stack. Apply through
`manage-credentials.py`. The new Key Vault version propagates to the runtime
Secret. Verify ARC authentication before revoking the prior GitHub key.
Restart/reconcile the listener if it does not pick up the new credential.

Recover the kubeconfig or SSH file through authenticated Key Vault reads;
decode the stored base64 into a local file with mode 600. For the App key,
download the JSON to an ignored local file and extract its PEM field without
printing it. Do not use Terraform data sources to read the secret back, since
ordinary data-source values would persist in Terraform state.

## Teardown

Destroy the ARC stack first, then the credentials stack through the wrapper,
then the Azure stack. This unregisters runners before removing credential
access. Key Vault secrets and the vault remain soft-deleted and recoverable;
the provider is configured not to purge them. Purge protection prevents early
permanent vault deletion. A new deployment using the same vault name during
the retention window must account for the soft-deleted vault.

## References

- [Terraform write-only arguments](https://developer.hashicorp.com/terraform/language/manage-sensitive-data/write-only)
- [External Secrets Azure Key Vault provider](https://external-secrets.io/latest/provider/azure-key-vault/)
- [AzureRM Key Vault secret](https://registry.terraform.io/providers/hashicorp/azurerm/4.76.0/docs/resources/key_vault_secret)
