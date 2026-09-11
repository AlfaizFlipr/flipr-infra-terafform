#!/usr/bin/env bash
set -Eeuo pipefail

echo "=========================================================="
echo " Configuring Ingress-NGINX (HostPort & LoadBalancer) & Argo"
echo "=========================================================="

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

# 1. Clean up duplicate flipr.local entries from /etc/hosts
echo "--> Cleaning up /etc/hosts..."
sudo sed -i '/flipr\.local/d' /etc/hosts || true

# 2. Create Namespaces
for ns in ingress-nginx argocd argo-rollouts jenkins registry default; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# 3. Generate Wildcard TLS Certificate for *.flipr.local
echo "--> Generating wildcard TLS certificate for *.flipr.local..."
TMP_TLS_DIR="/tmp/flipr-tls"
mkdir -p "${TMP_TLS_DIR}"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "${TMP_TLS_DIR}/tls.key" -out "${TMP_TLS_DIR}/tls.crt" \
  -subj "/CN=*.flipr.local/O=Flipr" \
  -addext "subjectAltName=DNS:*.flipr.local,DNS:flipr.local,DNS:jenkins.flipr.local,DNS:argocd.flipr.local,DNS:rollouts.flipr.local,DNS:registry.flipr.local" 2>/dev/null || \
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "${TMP_TLS_DIR}/tls.key" -out "${TMP_TLS_DIR}/tls.crt" \
  -subj "/CN=*.flipr.local/O=Flipr"

# 4. Create TLS Secret in all relevant namespaces
for ns in ingress-nginx argocd argo-rollouts jenkins registry default; do
    kubectl create secret tls flipr-wildcard-tls \
      --key "${TMP_TLS_DIR}/tls.key" \
      --cert "${TMP_TLS_DIR}/tls.crt" \
      -n "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# 5. Install / Update Ingress-NGINX Controller with hostPort.enabled=true
echo "--> Installing Ingress-NGINX with HostPort & LoadBalancer..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.hostPort.enabled=true \
  --set controller.extraArgs.default-ssl-certificate=ingress-nginx/flipr-wildcard-tls \
  --wait --timeout 5m

# 6. Install Argo CD (Server-Side Apply)
echo "--> Installing Argo CD..."
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}'

# 7. Install Argo Rollouts Controller, Dashboard UI & CLI
echo "--> Installing Argo Rollouts..."
kubectl apply --server-side --force-conflicts -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/dashboard-install.yaml

if ! command -v kubectl-argo-rollouts >/dev/null 2>&1; then
    curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
    chmod +x ./kubectl-argo-rollouts-linux-amd64
    sudo mv ./kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
fi

# 8. Apply Ingress routes
echo "--> Applying Ingress routes..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [ -f "${REPO_ROOT}/kubernetes/manifests/argo-cd/argocd-ingress.yaml" ]; then
    kubectl apply -f "${REPO_ROOT}/kubernetes/manifests/argo-cd/argocd-ingress.yaml"
fi
if [ -f "${REPO_ROOT}/kubernetes/manifests/argo-rollouts/rollouts-dashboard-ingress.yaml" ]; then
    kubectl apply -f "${REPO_ROOT}/kubernetes/manifests/argo-rollouts/rollouts-dashboard-ingress.yaml"
fi
if [ -f "${REPO_ROOT}/kubernetes/manifests/ingress-routes/jenkins-ingress.yaml" ]; then
    kubectl apply -f "${REPO_ROOT}/kubernetes/manifests/ingress-routes/jenkins-ingress.yaml"
fi
if [ -f "${REPO_ROOT}/kubernetes/manifests/ingress-routes/registry-ingress.yaml" ]; then
    kubectl apply -f "${REPO_ROOT}/kubernetes/manifests/ingress-routes/registry-ingress.yaml"
fi

kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-server -n argocd --timeout=5m
kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=5m
kubectl rollout status deployment/argo-rollouts-dashboard -n argo-rollouts --timeout=5m

# 9. Update /etc/hosts on local Ubuntu system
echo "--> Updating /etc/hosts for local access..."
sudo bash -c 'cat << EOF >> /etc/hosts
127.0.0.1 jenkins.flipr.local argocd.flipr.local rollouts.flipr.local registry.flipr.local
EOF'

# 10. Get MetalLB IP
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "192.168.1.240")

echo "=========================================================="
echo " Setup Completed Successfully!"
echo "=========================================================="
echo "Locally on this Ubuntu machine: /etc/hosts is updated with 127.0.0.1"
echo "On other LAN devices (e.g. Windows laptop), add to /etc/hosts:"
echo "${INGRESS_IP} jenkins.flipr.local argocd.flipr.local rollouts.flipr.local registry.flipr.local"
echo ""
echo "Test on Ubuntu terminal:"
echo "curl -k https://rollouts.flipr.local"
echo ""
echo "Argo CD Admin Username: admin"
echo -n "Argo CD Admin Password: "
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "admin secret"
echo ""
echo ""
echo "Access Points:"
echo " - Argo Rollouts UI:     https://rollouts.flipr.local  or  http://rollouts.flipr.local"
echo " - Argo CD UI:           https://argocd.flipr.local    or  http://argocd.flipr.local"
echo " - Jenkins UI:           https://jenkins.flipr.local   or  http://jenkins.flipr.local"
echo "=========================================================="
