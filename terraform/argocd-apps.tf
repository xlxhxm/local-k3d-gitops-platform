# ---------------------------------------------------------------------------
# Argo CD Application: infrastructure
# Monitors infrastructure/ directory — deploys MySQL + backup CronJob
# ---------------------------------------------------------------------------

resource "kubernetes_manifest" "argocd_app_infrastructure" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "infrastructure"
      namespace = var.argocd_namespace
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.git_repo_url
        targetRevision = var.git_target_revision
        path           = "infrastructure"
        directory = {
          recurse = true
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.infrastructure_namespace
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true"
        ]
      }
    }
  }

  depends_on = [null_resource.wait_for_argocd]
}

# ---------------------------------------------------------------------------
# Argo CD Application: applications
# Monitors applications/ directory — deploys custom Helm chart
# ---------------------------------------------------------------------------

resource "kubernetes_manifest" "argocd_app_applications" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "applications"
      namespace = var.argocd_namespace
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.git_repo_url
        targetRevision = var.git_target_revision
        path           = "applications/app-chart"
        helm = {
          valueFiles = ["values.yaml"]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = var.applications_namespace
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true"
        ]
      }
    }
  }

  depends_on = [null_resource.wait_for_argocd]
}
