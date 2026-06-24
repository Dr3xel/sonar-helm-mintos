resource "helm_release" "postgresql" {
  name      = "postgresql"
  namespace = kubernetes_namespace.sonarqube.metadata[0].name

  chart            = "${path.module}/../helm/postgresql"
  lint             = true
  create_namespace = false

  wait            = true
  timeout         = 600
  cleanup_on_fail = true
  force_update    = true
}

resource "helm_release" "sonarqube" {
  name      = "sonarqube"
  namespace = kubernetes_namespace.sonarqube.metadata[0].name

  chart            = "${path.module}/../helm/sonarqube"
  lint             = true
  create_namespace = false

  wait            = true
  timeout         = 900
  cleanup_on_fail = true
  force_update    = true

  depends_on = [
    helm_release.postgresql
  ]
}