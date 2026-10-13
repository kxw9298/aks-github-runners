variable "kubeconfig_path" {
  type    = string
  default = "../../../.poc-state/kubeconfig"
}

variable "arc_version" {
  type    = string
  default = "0.15.0"
}

variable "repository" {
  type    = string
  default = "kxw9298/aks-github-runners"
}

variable "scale_set_name" {
  type    = string
  default = "aks-poc-linux"
}

variable "enable_runners" {
  type        = bool
  description = "Enable only after registering and installing the GitHub App."
  default     = false
}

variable "key_vault_uri" {
  type        = string
  description = "Azure stack key_vault_uri output."
}

variable "vault_reader_client_id" {
  type        = string
  description = "Azure stack vault_reader_client_id output."
}

variable "tenant_id" {
  type        = string
  description = "Azure stack tenant_id output."
}
