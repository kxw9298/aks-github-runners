resource "azurerm_resource_group" "poc" {
  name     = var.resource_group_name
  location = var.location
  tags = {
    purpose = "github-runner-poc"
    owner   = "kxw9298"
  }
}

resource "azurerm_kubernetes_cluster" "poc" {
  name                = var.cluster_name
  location            = azurerm_resource_group.poc.location
  resource_group_name = azurerm_resource_group.poc.name
  dns_prefix          = var.dns_prefix
  kubernetes_version  = var.kubernetes_version
  sku_tier            = "Free"
  node_resource_group = "MC_${var.resource_group_name}_${var.cluster_name}_${var.location}"

  role_based_access_control_enabled = true
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  node_os_upgrade_channel           = "NodeImage"

  default_node_pool {
    name                 = "system"
    node_count           = 1
    vm_size              = var.node_vm_size
    os_sku               = "AzureLinux3"
    os_disk_size_gb      = 64
    os_disk_type         = "Managed"
    max_pods             = 250
    orchestrator_version = var.kubernetes_version
    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  linux_profile {
    admin_username = "azureuser"
    ssh_key {
      key_data = file(var.ssh_public_key_file)
    }
  }

  api_server_access_profile {
    authorized_ip_ranges = var.authorized_ip_ranges
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
    pod_cidr            = "10.244.0.0/16"
    service_cidr        = "10.0.0.0/16"
    dns_service_ip      = "10.0.0.10"
    load_balancer_profile {
      managed_outbound_ip_count = 1
      idle_timeout_in_minutes   = 30
    }
  }

  tags = azurerm_resource_group.poc.tags
}
