output "cluster_name" {
  value = azurerm_kubernetes_cluster.poc.name
}

output "resource_group_name" {
  value = azurerm_resource_group.poc.name
}

output "cluster_id" {
  value = azurerm_kubernetes_cluster.poc.id
}
