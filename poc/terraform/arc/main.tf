resource "kubernetes_namespace_v1" "system" {
  metadata {
    name = "arc-system"
  }
}

resource "kubernetes_namespace_v1" "runners" {
  metadata {
    name = "arc-runners"
  }
}

resource "kubernetes_config_map_v1" "hook" {
  metadata {
    name      = "runner-hook-template"
    namespace = kubernetes_namespace_v1.runners.metadata[0].name
  }
  data = yamldecode(file("${path.module}/../../hook-template.yaml")).data
}

resource "helm_release" "controller" {
  name       = "arc"
  namespace  = kubernetes_namespace_v1.system.metadata[0].name
  repository = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart      = "gha-runner-scale-set-controller"
  version    = var.arc_version
  values     = [file("${path.module}/../../controller-values.yaml")]
  wait       = true
  timeout    = 300
}

resource "kubernetes_secret_v1" "github_app" {
  count = var.enable_runners ? 1 : 0
  metadata {
    name      = "github-app"
    namespace = kubernetes_namespace_v1.runners.metadata[0].name
  }
  data = {
    github_app_id              = var.github_app_id
    github_app_installation_id = var.github_app_installation_id
    github_app_private_key     = var.enable_runners ? sensitive(file(var.github_app_private_key_file)) : ""
  }
  lifecycle {
    precondition {
      condition     = var.github_app_id != "" && var.github_app_installation_id != ""
      error_message = "Set both GitHub App and installation IDs before enabling runners."
    }
  }
}

resource "helm_release" "runners" {
  count      = var.enable_runners ? 1 : 0
  name       = var.scale_set_name
  namespace  = kubernetes_namespace_v1.runners.metadata[0].name
  repository = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart      = "gha-runner-scale-set"
  version    = var.arc_version
  values = [
    file("${path.module}/../../runner-values.yaml"),
    yamlencode({
      githubConfigUrl    = "https://github.com/${var.repository}"
      githubConfigSecret = kubernetes_secret_v1.github_app[0].metadata[0].name
      runnerScaleSetName = var.scale_set_name
    })
  ]
  wait    = true
  timeout = 300
  depends_on = [
    helm_release.controller,
    kubernetes_config_map_v1.hook,
  ]
}
