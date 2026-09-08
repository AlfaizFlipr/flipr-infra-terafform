# Split server and Kubernetes Terraform configuration

This repository has two independent Terraform roots:

| Folder | Owns | Apply frequency |
| --- | --- | --- |
| `server/` | Ubuntu prerequisites and the single-node K3s server | When creating or rebuilding a server |
| `kubernetes/` | Kube-VIP, MetalLB, Longhorn, Docker Registry, Jenkins, and future cluster workloads | Whenever Kubernetes configuration changes |

Each folder has separate Terraform state, variables, generated scripts, and provider initialization. Run Terraform only from the relevant directory.

## Deploy

First prepare the server:

```bash
cd server
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply
```

Then deploy Kubernetes configuration:

```bash
cd ../kubernetes
cp terraform.tfvars.example terraform.tfvars
# Set unused LAN addresses for kube_vip and metallb_address_pool.
terraform init
terraform apply
```

`kubernetes/` expects K3s from `server/`, using `/etc/rancher/k3s/k3s.yaml` by default. Set `kubeconfig_path` in `kubernetes/terraform.tfvars` only if required.

## Existing deployment migration

Do not run `terraform destroy` in the former repository root. Its state only tracked the local bootstrap file and command record; it did not manage Kubernetes objects directly. Initialize and apply `server/`, then `kubernetes/`, to establish the new independent states and reconcile installed Helm releases.

Kube-VIP and MetalLB addresses must be unused, on the same L2 network as the node, and excluded from DHCP. This remains a single-node setup; the VIP does not provide high availability.
