output "kubernetes_api" {
  value = "https://${var.kube_vip}:6443"
}
output "service_commands" {
  value = { registry = "kubectl -n registry get svc docker-registry", jenkins = "kubectl -n jenkins get svc jenkins", longhorn = "kubectl -n longhorn-system get pods" }
}
