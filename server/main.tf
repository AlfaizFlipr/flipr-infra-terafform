locals {
  rendered_bootstrap = templatefile("${path.module}/scripts/bootstrap-server.sh.tftpl", { k3s_version = var.k3s_version })
}
resource "local_file" "bootstrap" {
  content = local.rendered_bootstrap
  filename = "${path.module}/.generated-bootstrap-server.sh"
  file_permission = "0700"
}
resource "null_resource" "server" {
  depends_on = [local_file.bootstrap]
  triggers = { bootstrap_sha = sha256(local.rendered_bootstrap) }
  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]
    command = "sudo ${local_file.bootstrap.filename}"
  }
}
