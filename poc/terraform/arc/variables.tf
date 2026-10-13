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

variable "github_app_id" {
  type    = string
  default = ""
}

variable "github_app_installation_id" {
  type    = string
  default = ""
}

variable "github_app_private_key_file" {
  type        = string
  description = "Local PEM path. Key content will be sensitive, but stored in Terraform state."
  default     = "../../../.poc-state/github-app.pem"
}
