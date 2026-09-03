variable "node_host" {
  description = "DNS name or IP address of the single Linux node."
  type        = string
}

variable "ssh_user" {
  description = "SSH user with passwordless sudo on the node."
  type        = string
  default     = "ubuntu"
}

variable "ssh_private_key_path" {
  description = "Path to the private SSH key used to reach the node."
  type        = string
}

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

variable "remote_script_path" {
  description = "Temporary path used for the generated remote bootstrap script."
  type        = string
  default     = "/tmp/k3s-platform-bootstrap.sh"
}