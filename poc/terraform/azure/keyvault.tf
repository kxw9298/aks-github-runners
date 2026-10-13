data "azurerm_client_config" "current" {}

data "azurerm_public_ip" "aks_egress" {
  name                = basename(one(azurerm_kubernetes_cluster.poc.network_profile[0].load_balancer_profile[0].effective_outbound_ips))
  resource_group_name = azurerm_kubernetes_cluster.poc.node_resource_group
}

resource "azurerm_key_vault" "poc" {
  name                       = "kvakspoc${substr(sha256(var.subscription_id), 0, 10)}"
  location                   = azurerm_resource_group.poc.location
  resource_group_name        = azurerm_resource_group.poc.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 7
  network_acls {
    bypass         = "None"
    default_action = "Deny"
    ip_rules = concat(
      tolist(var.authorized_ip_ranges),
      ["${data.azurerm_public_ip.aks_egress.ip_address}/32"]
    )
  }
  tags = azurerm_resource_group.poc.tags
}

resource "azurerm_role_assignment" "vault_operator" {
  scope                = azurerm_key_vault.poc.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_user_assigned_identity" "vault_reader" {
  name                = "id-aks-poc-keyvault"
  location            = azurerm_resource_group.poc.location
  resource_group_name = azurerm_resource_group.poc.name
  tags                = azurerm_resource_group.poc.tags
}

resource "azurerm_federated_identity_credential" "vault_reader" {
  name                      = "arc-runners-keyvault"
  user_assigned_identity_id = azurerm_user_assigned_identity.vault_reader.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azurerm_kubernetes_cluster.poc.oidc_issuer_url
  subject                   = "system:serviceaccount:arc-runners:keyvault-reader"
}
