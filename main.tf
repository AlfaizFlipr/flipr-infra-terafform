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
    node_host     = var.node_host
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-NonInteractive", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = 'Stop'
      $key = '${var.ssh_private_key_path}'
      $hostName = '${var.node_host}'
      $user = '${var.ssh_user}'
      $remotePath = '${var.remote_script_path}'
      $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Content -Raw '${local_file.bootstrap.filename}')))
      ssh -o StrictHostKeyChecking=accept-new -i $key "$user@$hostName" "umask 077; printf '%s' '$payload' | base64 -d > $remotePath; chmod 700 $remotePath; sudo $remotePath"
      if ($LASTEXITCODE -ne 0) { throw "Remote platform bootstrap failed with exit code $LASTEXITCODE" }
    EOT
  }
}