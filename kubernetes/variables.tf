variable "kubeconfig_path" {
  description = "Path to the kubeconfig created by server Terraform."
  type = string
  default = "/etc/rancher/k3s/k3s.yaml"
}
variable "kube_vip" {
  description = "Unused L2 address for the Kubernetes API."
  type        = string
}

variable "metallb_address_pool" {
  description = "Unused L2 address range for LoadBalancer services."
  type        = string
}
variable "longhorn_replica_count" {
  description = "Longhorn replica count; a single node must use one replica."
  type = number
  default = 1
  validation {
    condition     = var.longhorn_replica_count == 1
    error_message = "A single-node cluster must use one Longhorn replica."
  }
}

variable "registry_storage_size" {
  description = "Persistent volume size for the Docker Registry."
  type        = string
  default     = "20Gi"
}

variable "jenkins_storage_size" {
  description = "Persistent volume size for Jenkins."
  type        = string
  default     = "20Gi"
}
