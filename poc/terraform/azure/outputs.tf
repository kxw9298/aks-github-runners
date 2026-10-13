output "cluster_name" {
  value = azurerm_kubernetes_cluster.poc.name
}

output "resource_group_name" {
  value = azurerm_resource_group.poc.name
}

output "cluster_id" {
  value = azurerm_kubernetes_cluster.poc.id
}

output "key_vault_id" {
  value = azurerm_key_vault.poc.id
}

output "key_vault_uri" {
  value = azurerm_key_vault.poc.vault_uri
}

output "key_vault_name" {
  value = azurerm_key_vault.poc.name
}

output "vault_reader_client_id" {
  value = azurerm_user_assigned_identity.vault_reader.client_id
}

output "vault_reader_principal_id" {
  value = azurerm_user_assigned_identity.vault_reader.principal_id
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}
