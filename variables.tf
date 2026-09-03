variable "kube_vip" {
  description = "Unused L2 address on the node's LAN for the Kubernetes API."
  type        = string
}

variable "metallb_address_pool" {
  description = "Unused L2 address range for Kubernetes LoadBalancer services."
  type        = string
}

variable "k3s_version" {
  description = "K3s channel/version passed to the official installer."
  type        = string
  default     = "stable"
}

variable "longhorn_replica_count" {
  description = "Longhorn replica count; a single node must use one replica."
  type        = number
  default     = 1

  validation {
    condition     = var.longhorn_replica_count == 1
    error_message = "A single-node cluster cannot provide redundant Longhorn replicas; use 1."
  }
}

variable "registry_storage_size" {
  description = "Persistent volume size for the private Docker Registry."
  type        = string
  default     = "20Gi"
}

variable "jenkins_storage_size" {
  description = "Persistent volume size for Jenkins."
  type        = string
  default     = "20Gi"
}
