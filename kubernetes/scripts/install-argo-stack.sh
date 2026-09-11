#!/usr/bin/env bash
set -Eeuo pipefail

echo "=========================================================="
echo " Configuring Ingress-NGINX with TLS & Argo Stack"
echo "=========================================================="

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

# 1. Create Namespaces
echo "--> Creating namespaces: ingress-nginx, argocd, argo-rollouts, jenkins, registry..."
for ns in ingress-nginx argocd argo-rollouts jenkins registry default; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# 2. Generate Wildcard TLS Certificate for *.flipr.local
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

# 3. Create TLS Secret in all relevant namespaces
echo "--> Applying TLS secret to namespaces..."
for ns in ingress-nginx argocd argo-rollouts jenkins registry default; do
    kubectl create secret tls flipr-wildcard-tls \
      --key "${TMP_TLS_DIR}/tls.key" \
      --cert "${TMP_TLS_DIR}/tls.crt" \
      -n "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# 4. Install / Update Ingress-NGINX Controller
echo "--> Installing / Updating Ingress-NGINX with default SSL certificate..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.extraArgs.default-ssl-certificate=ingress-nginx/flipr-wildcard-tls \
  --wait --timeout 5m

# 5. Install Argo CD (Using Server-Side Apply)
echo "--> Installing Argo CD core & server components..."
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Configure Argo CD Server Insecure Mode for Ingress
echo "--> Configuring Argo CD server insecure mode..."
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}'

# 6. Install Argo Rollouts (Controller & CRDs using Server-Side Apply)
echo "--> Installing Argo Rollouts Controller & CRDs..."
kubectl apply --server-side --force-conflicts -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# 7. Install Argo Rollouts Dashboard UI
echo "--> Installing Argo Rollouts Dashboard Web UI..."
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/dashboard-install.yaml

# 8. Install kubectl-argo-rollouts CLI Plugin
echo "--> Installing kubectl-argo-rollouts CLI plugin..."
if ! command -v kubectl-argo-rollouts >/dev/null 2>&1; then
    curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
    chmod +x ./kubectl-argo-rollouts-linux-amd64
    sudo mv ./kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
    echo "kubectl-argo-rollouts plugin installed successfully!"
fi

# 9. Apply Ingress routes for all Dashboards
echo "--> Applying Ingress routes for Dashboards..."
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

# Restart Argo CD Server to pick up config
kubectl rollout restart deployment/argocd-server -n argocd

# 10. Wait for Deployments to be Ready
echo "--> Waiting for deployments to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=5m
kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=5m
kubectl rollout status deployment/argo-rollouts-dashboard -n argo-rollouts --timeout=5m

# 11. Fetch Ingress LoadBalancer IP from MetalLB
INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "192.168.1.240")

# 12. Print Summary
echo "=========================================================="
echo " Ingress & Argo Stack Setup Completed!"
echo "=========================================================="
echo "Ingress LoadBalancer IP: ${INGRESS_IP}"
echo ""
echo "Argo CD Admin Username: admin"
echo -n "Argo CD Admin Password: "
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "admin secret"
echo ""
echo ""
echo "Access URLs (Both HTTP and HTTPS now work!):"
echo " - Argo Rollouts UI:     http://rollouts.flipr.local  or  https://rollouts.flipr.local"
echo " - Argo CD UI:           http://argocd.flipr.local    or  https://argocd.flipr.local"
echo " - Jenkins UI:           http://jenkins.flipr.local   or  https://jenkins.flipr.local"
echo " - Docker Registry:      http://registry.flipr.local  or  https://registry.flipr.local"
echo "=========================================================="
