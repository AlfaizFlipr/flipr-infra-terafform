#!/usr/bin/env bash
set -euo pipefail

echo "==> Configuring K3s containerd to pull images from in-cluster registry..."

# 1. Get the ClusterIP of docker-registry service
REGISTRY_IP=$(kubectl get svc docker-registry -n registry -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

if [ -z "${REGISTRY_IP}" ]; then
    echo "ERROR: docker-registry service not found in registry namespace."
    exit 1
fi

echo "Found Docker Registry ClusterIP: ${REGISTRY_IP}:5000"

# 2. Create /etc/rancher/k3s directory if not exists
sudo mkdir -p /etc/rancher/k3s

# 3. Write /etc/rancher/k3s/registries.yaml
sudo tee /etc/rancher/k3s/registries.yaml > /dev/null <<EOF
mirrors:
  "docker-registry.registry.svc.cluster.local:5000":
    endpoint:
      - "http://${REGISTRY_IP}:5000"
  "registry.flipr.local":
    endpoint:
      - "http://127.0.0.1:80"
configs:
  "docker-registry.registry.svc.cluster.local:5000":
    tls:
      insecure_skip_verify: true
  "registry.flipr.local":
    tls:
      insecure_skip_verify: true
EOF

echo "==> /etc/rancher/k3s/registries.yaml written successfully:"
cat /etc/rancher/k3s/registries.yaml

# 4. Restart K3s to apply containerd registry configuration
echo "==> Restarting K3s service..."
sudo systemctl restart k3s

echo "==> Waiting for cluster to be ready..."
sleep 5
kubectl get nodes

echo "==> Deleting failed application pods so they pull afresh..."
kubectl delete pods -n default --field-selector=status.phase=Pending 2>/dev/null || true
kubectl delete pods -n default -l app=flipr-demo-app-api 2>/dev/null || true
kubectl delete pods -n default -l app=flipr-demo-app-web 2>/dev/null || true

echo "==> Done! All pods will now pull images directly from the local registry."
