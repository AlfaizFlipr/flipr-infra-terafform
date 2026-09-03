locals {
  rendered_bootstrap = templatefile("${path.module}/scripts/bootstrap.sh.tftpl", {
    kube_vip               = var.kube_vip
    metallb_address_pool   = var.metallb_address_pool
    k3s_version            = var.k3s_version
    longhorn_replica_count = var.longhorn_replica_count
    registry_storage_size  = var.registry_storage_size
    jenkins_storage_size   = var.jenkins_storage_size
  })
}

resource "local_file" "bootstrap" {
  content         = local.rendered_bootstrap
  filename        = "${path.module}/.generated-bootstrap.sh"
  file_permission = "0700"
}

resource "null_resource" "platform" {
  depends_on = [local_file.bootstrap]

  triggers = {
    bootstrap_sha = sha256(local.rendered_bootstrap)
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]
    command     = "sudo ${local_file.bootstrap.filename}"
  }
}
