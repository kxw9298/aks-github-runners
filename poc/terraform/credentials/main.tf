terraform {
  required_version = ">= 1.11.0, < 2.0.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.76.0"
    }
  }
}

provider "azurerm" {
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
  features {
    key_vault {
      purge_soft_deleted_secrets_on_destroy = false
    }
  }
}

variable "subscription_id" {
  type = string
}

variable "key_vault_id" {
  type = string
}

variable "vault_reader_principal_id" {
  type = string
}

variable "credential_revision" {
  type        = number
  default     = 1
  description = "Increment when rotating credentials; write-only values cannot be diffed."
}

variable "include_aks_recovery_credentials" {
  type        = bool
  default     = false
  description = "Requires explicit approval to upload cluster/node recovery credentials."
}

variable "secret_values" {
  type        = map(string)
  sensitive   = true
  ephemeral   = true
  description = "Provided transiently by manage-credentials.py; never stored in plans or state."
}

resource "azurerm_key_vault_secret" "credential" {
  for_each         = toset(var.include_aks_recovery_credentials ? ["github-app-credentials", "aks-kubeconfig", "aks-ssh-private-key"] : ["github-app-credentials"])
  name             = each.key
  key_vault_id     = var.key_vault_id
  value_wo         = var.secret_values[each.key]
  value_wo_version = var.credential_revision
  content_type     = each.key == "github-app-credentials" ? "application/json" : "application/base64"
}

# The runtime identity cannot retrieve the AKS admin kubeconfig or SSH key.
resource "azurerm_role_assignment" "app_reader" {
  scope                = "${var.key_vault_id}/secrets/github-app-credentials"
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.vault_reader_principal_id
  depends_on           = [azurerm_key_vault_secret.credential]
}
