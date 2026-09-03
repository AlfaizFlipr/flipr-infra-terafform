output "kubernetes_api" {
  description = "Kubernetes API endpoint through Kube-VIP."
  value       = "https://${var.kube_vip}:6443"
}

output "node_ssh_command" {
  description = "SSH command for inspecting the node."
  value       = "ssh -i ${var.ssh_private_key_path} ${var.ssh_user}@${var.node_host}"
}

output "service_commands" {
  description = "Commands for service discovery."
  value = {
    registry = "kubectl -n registry get svc docker-registry"
    jenkins  = "kubectl -n jenkins get svc jenkins"
    longhorn = "kubectl -n longhorn-system get pods"
  }
}