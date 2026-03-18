# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "argocd_namespace" {
  description = "Namespace where Argo CD is installed"
  value       = kubernetes_namespace.argocd.metadata[0].name
}

output "argocd_server_url" {
  description = "URL to access the Argo CD UI (via k3d port mapping: host 8443 → NodePort 30443)"
  value       = "https://localhost:8443"
}

output "argocd_initial_password_command" {
  description = "Command to retrieve the initial Argo CD admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo"
}

output "infrastructure_app" {
  description = "Name of the Argo CD infrastructure Application"
  value       = "infrastructure"
}

output "applications_app" {
  description = "Name of the Argo CD applications Application"
  value       = "applications"
}
