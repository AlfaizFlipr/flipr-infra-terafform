#!/usr/bin/env bash
set -Eeuo pipefail

echo "=========================================================="
echo " Installing Ingress-NGINX, Argo CD & Argo Rollouts Stack"
echo "=========================================================="

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

# 1. Install Ingress-NGINX Controller (Takes LoadBalancer IP from MetalLB)
echo "--> Installing Ingress-NGINX Controller via Helm..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.externalTrafficPolicy=Local \
  --wait --timeout 5m

# 2. Create Namespaces for Argo
echo "--> Creating namespaces: argocd & argo-rollouts..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -

# 3. Install Argo CD (Using Server-Side Apply)
echo "--> Installing Argo CD core & server components..."
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Configure Argo CD Server Insecure Mode for HTTP Ingress
echo "--> Configuring Argo CD server insecure mode for HTTP Ingress..."
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}'

# 4. Install Argo Rollouts (Controller & CRDs using Server-Side Apply)
echo "--> Installing Argo Rollouts Controller & CRDs..."
kubectl apply --server-side --force-conflicts -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# 5. Install Argo Rollouts Dashboard UI
echo "--> Installing Argo Rollouts Dashboard Web UI..."
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/dashboard-install.yaml

# 6. Install kubectl-argo-rollouts CLI Plugin
echo "--> Installing kubectl-argo-rollouts CLI plugin..."
if ! command -v kubectl-argo-rollouts >/dev/null 2>&1; then
    curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
    chmod +x ./kubectl-argo-rollouts-linux-amd64
    sudo mv ./kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
    echo "kubectl-argo-rollouts plugin installed successfully!"
fi

# 7. Apply Ingress routes for all Dashboards
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

# Restart Argo CD Server to pick up insecure HTTP config
kubectl rollout restart deployment/argocd-server -n argocd

# 8. Wait for Deployments to be Ready
echo "--> Waiting for deployments to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=5m
kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=5m
kubectl rollout status deployment/argo-rollouts-dashboard -n argo-rollouts --timeout=5m

# 9. Fetch Ingress LoadBalancer IP from MetalLB
INGRESS_IP=""
for i in {1..30}; do
    INGRESS_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "${INGRESS_IP}" ]; then
        break
    fi
    echo "Waiting for MetalLB to assign IP to Ingress controller..."
    sleep 2
done

if [ -z "${INGRESS_IP}" ]; then
    INGRESS_IP="127.0.0.1"
fi

# 10. Print Summary & Setup Info
echo "=========================================================="
echo " Ingress & Argo Stack Installation Completed!"
echo "=========================================================="
echo "Ingress LoadBalancer IP: ${INGRESS_IP}"
echo ""
echo "Add the following line to /etc/hosts on your machine:"
echo "${INGRESS_IP} jenkins.flipr.local argocd.flipr.local rollouts.flipr.local registry.flipr.local"
echo ""
echo "Argo CD Admin Username: admin"
echo -n "Argo CD Admin Password: "
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "admin secret"
echo ""
echo ""
echo "Access Points (HTTP):"
echo " - Argo CD UI:           http://argocd.flipr.local"
echo " - Argo Rollouts UI:     http://rollouts.flipr.local"
echo " - Jenkins UI:           http://jenkins.flipr.local"
echo " - Docker Registry:      http://registry.flipr.local"
echo "=========================================================="
