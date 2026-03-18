terraform {
  required_version = ">= 1.5.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# ---------------------------------------------------------------------------
# Providers – use the kubeconfig that k3d writes
# ---------------------------------------------------------------------------

provider "helm" {
  kubernetes {
    config_path    = var.kubeconfig_path
    config_context = var.kubeconfig_context
  }
}

provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kubeconfig_context
}

provider "kubectl" {
  config_path    = var.kubeconfig_path
  config_context = var.kubeconfig_context
}

# ---------------------------------------------------------------------------
# Namespace for Argo CD
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = var.argocd_namespace
  }
}

# ---------------------------------------------------------------------------
# Install Argo CD via its official Helm chart
# ---------------------------------------------------------------------------

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  # Override generated resource names so deployments are named
  # argocd-server, argocd-repo-server, etc. (not argocd-argo-cd-*)
  set {
    name  = "fullnameOverride"
    value = "argocd"
  }

  # Expose the server as NodePort so it is reachable via k3d port mapping
  set {
    name  = "server.service.type"
    value = "NodePort"
  }

  set {
    name  = "server.service.nodePortHttps"
    value = var.argocd_nodeport
  }

  # Reduce resource footprint for local development
  set {
    name  = "controller.replicas"
    value = "1"
  }

  set {
    name  = "repoServer.replicas"
    value = "1"
  }

  wait    = true
  timeout = 600

  depends_on = [kubernetes_namespace.argocd]
}

# ---------------------------------------------------------------------------
# Wait for Argo CD to be fully ready before creating Application CRDs
# ---------------------------------------------------------------------------

resource "null_resource" "wait_for_argocd" {
  depends_on = [helm_release.argocd]

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for Argo CD server to be ready..."
      kubectl --context ${var.kubeconfig_context} -n ${var.argocd_namespace} \
        rollout status deployment/argocd-server --timeout=300s
      echo "Argo CD server is ready."
    EOT
  }
}
