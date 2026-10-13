variable "subscription_id" {
  type        = string
  description = "Azure subscription in which to deploy the isolated PoC."
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "resource_group_name" {
  type    = string
  default = "rg-aks-github-runners-poc"
}

variable "cluster_name" {
  type    = string
  default = "aks-github-runners-poc"
}

variable "dns_prefix" {
  type        = string
  description = "Stable cluster DNS prefix. Preserve the deployed prefix when importing."
  default     = "aks-github-runners-poc"
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"
}

variable "node_vm_size" {
  type    = string
  default = "Standard_D4s_v4"
}

variable "authorized_ip_ranges" {
  type        = set(string)
  description = "Public client CIDRs allowed to reach the PoC API; never use 0.0.0.0/0."
  validation {
    condition     = length(var.authorized_ip_ranges) > 0 && alltrue([for cidr in var.authorized_ip_ranges : can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0"])
    error_message = "Supply at least one valid, restricted IPv4 CIDR."
  }
}

variable "ssh_public_key_file" {
  type        = string
  description = "Path to an existing SSH public key; its private key stays outside Terraform."
}
