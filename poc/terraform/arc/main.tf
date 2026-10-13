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

removed {
  from = kubernetes_secret_v1.github_app
  lifecycle {
    destroy = false
  }
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  namespace  = kubernetes_namespace_v1.system.metadata[0].name
  repository = "oci://ghcr.io/external-secrets/charts"
  chart      = "external-secrets"
  version    = "2.12.0"
  values     = [file("${path.module}/../../external-secrets-values.yaml")]
  wait       = true
  timeout    = 600
}

resource "helm_release" "keyvault_sync" {
  count     = var.enable_runners ? 1 : 0
  name      = "github-app-keyvault"
  namespace = kubernetes_namespace_v1.runners.metadata[0].name
  chart     = "${path.module}/../../charts/keyvault-sync"
  values = [yamlencode({
    vaultUrl = var.key_vault_uri
    clientId = var.vault_reader_client_id
    tenantId = var.tenant_id
  })]
  wait       = true
  timeout    = 300
  depends_on = [helm_release.external_secrets]
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
      githubConfigSecret = "github-app"
      runnerScaleSetName = var.scale_set_name
    })
  ]
  wait    = true
  timeout = 300
  depends_on = [
    helm_release.controller,
    kubernetes_config_map_v1.hook,
    helm_release.keyvault_sync,
  ]
}
