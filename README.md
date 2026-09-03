# Single-node K3s platform with Terraform

This project provisions a single Linux node over SSH with Terraform from a Windows workstation. One `terraform apply` installs and validates:

- K3s, configured as a single server
- Kube-VIP for the Kubernetes API VIP
- Helm 3
- MetalLB with an L2 address pool for `LoadBalancer` services
- Longhorn with one replica, which is the only viable setting on one node
- An internal Docker Registry Helm release
- Jenkins Helm release with persistent storage

Kube-VIP and MetalLB require unused addresses on the same L2 network as the node. This is API endpoint failover plumbing, not true high availability: one node remains a single point of failure.

## Windows host requirements

K3s and Longhorn are Linux components and cannot run natively in Windows. To run the complete platform on this same physical Windows machine, create one Ubuntu 22.04/24.04 VM using Hyper-V or VirtualBox. Attach the VM to an External/Bridged network adapter so its node IP, Kube-VIP, and MetalLB pool are on the same LAN. Do not use NAT networking for this setup because ARP-based VIP and MetalLB advertisement will not work correctly.

The Ubuntu VM needs systemd, at least 4 vCPUs, 8 GB RAM, 60 GB free disk, and an SSH user with passwordless sudo. Enable OpenSSH Server in the VM and verify from Windows:

```powershell
ssh -i C:/Users/you/.ssh/id_ed25519 ubuntu@192.168.1.50
```

WSL2 is suitable for experimenting with K3s, but its virtual networking does not provide the LAN L2 behavior required by this Kube-VIP and MetalLB configuration. Use a bridged Linux VM for the complete requested stack.

## Usage

1. Install Terraform 1.5+ on Windows and ensure `terraform`, `ssh`, and `scp` are on `PATH`.
2. Copy `terraform.tfvars.example` to `terraform.tfvars` and replace every example value.
3. Confirm the VIP and MetalLB range are not assigned by DHCP or another host.
4. Run:

```powershell
terraform init
terraform apply -auto-approve
```

The `terraform apply -auto-approve` command is the single provisioning command; `terraform init` is only the one-time provider download. The apply streams remote validation output. Terraform state contains the node connection metadata, so keep it private.

## Access

The Registry and Jenkins services are intentionally `ClusterIP` and are not exposed to the LAN by default. On the node, inspect them with:

```bash
kubectl -n registry get svc docker-registry
kubectl -n jenkins get svc jenkins
kubectl -n longhorn-system get pods
```

For a temporary local Jenkins tunnel, use `kubectl -n jenkins port-forward svc/jenkins 8080:8080`. The initial admin password is available from the Jenkins secret in that namespace.

## Re-running and removal

The bootstrap uses `helm upgrade --install` and is safe to rerun after a failed rollout. `terraform apply` reruns when the rendered configuration or target host changes. `terraform destroy` only removes Terraform's local state/resource record; it does not uninstall software from the remote node. Remove the platform deliberately with `sudo /usr/local/bin/k3s-uninstall.sh` on the node after backing up data.