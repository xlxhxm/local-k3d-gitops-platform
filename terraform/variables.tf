# ---------------------------------------------------------------------------
# General
# ---------------------------------------------------------------------------

variable "kubeconfig_path" {
  description = "Path to the kubeconfig file"
  type        = string
  default     = "~/.kube/config"
}

variable "kubeconfig_context" {
  description = "Kubernetes context to use (k3d cluster context)"
  type        = string
  default     = "k3d-gitops-cluster"
}

# ---------------------------------------------------------------------------
# Argo CD
# ---------------------------------------------------------------------------

variable "argocd_namespace" {
  description = "Namespace where Argo CD will be installed"
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = "Version of the Argo CD Helm chart"
  type        = string
  default     = "5.55.0"
}

variable "argocd_nodeport" {
  description = "NodePort number for the Argo CD server HTTPS service"
  type        = string
  default     = "30443"
}

# ---------------------------------------------------------------------------
# Git repository (for Argo CD Applications)
# ---------------------------------------------------------------------------

variable "git_repo_url" {
  description = "URL of the Git repository containing manifests"
  type        = string
  default     = "https://github.com/<your-username>/k8s-gitops-demo.git"
}

variable "git_target_revision" {
  description = "Git branch, tag, or commit to track"
  type        = string
  default     = "main"
}

# ---------------------------------------------------------------------------
# Application namespaces
# ---------------------------------------------------------------------------

variable "infrastructure_namespace" {
  description = "Namespace for infrastructure workloads (MySQL, backups)"
  type        = string
  default     = "infrastructure"
}

variable "applications_namespace" {
  description = "Namespace for frontend/backend applications"
  type        = string
  default     = "applications"
}
