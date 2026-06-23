resource "kubernetes_namespace" "sonarqube" {
  metadata {
    name = var.namespace
  }
}