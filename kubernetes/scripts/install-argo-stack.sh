#!/usr/bin/env bash
set -Eeuo pipefail

echo "=========================================================="
echo " Installing Argo CD & Argo Rollouts Stack on K3s"
echo "=========================================================="

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

# 1. Create Namespaces
echo "--> Creating namespaces: argocd & argo-rollouts..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -

# 2. Install Argo CD (Using Server-Side Apply to avoid CRD annotation size limit)
echo "--> Installing Argo CD core & server components (server-side apply)..."
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Install Argo Rollouts (Controller & CRDs using Server-Side Apply)
echo "--> Installing Argo Rollouts Controller & CRDs (server-side apply)..."
kubectl apply --server-side --force-conflicts -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# 4. Install Argo Rollouts Dashboard UI
echo "--> Installing Argo Rollouts Dashboard Web UI..."
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/dashboard-install.yaml

# 5. Install kubectl-argo-rollouts CLI Plugin
echo "--> Installing kubectl-argo-rollouts CLI plugin..."
if ! command -v kubectl-argo-rollouts >/dev/null 2>&1; then
    curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
    chmod +x ./kubectl-argo-rollouts-linux-amd64
    sudo mv ./kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
    echo "kubectl-argo-rollouts plugin installed successfully!"
fi

# 6. Apply Ingress routes for Argo CD & Argo Rollouts Dashboards
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

# 7. Wait for Rollout Deployments to be Ready
echo "--> Waiting for Argo deployments to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=5m
kubectl rollout status deployment/argo-rollouts -n argo-rollouts --timeout=5m
kubectl rollout status deployment/argo-rollouts-dashboard -n argo-rollouts --timeout=5m

# 8. Print Argo CD Initial Admin Password
echo "=========================================================="
echo " Argo Stack Installation Completed Successfully!"
echo "=========================================================="
echo "Argo CD Admin Username: admin"
echo -n "Argo CD Admin Password: "
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "admin secret created"
echo ""
echo "Access Points:"
echo " - Argo CD UI:           http://argocd.flipr.local"
echo " - Argo Rollouts UI:     http://rollouts.flipr.local"
echo " - Jenkins UI:           http://jenkins.flipr.local"
echo " - Docker Registry:      http://registry.flipr.local"
echo "=========================================================="
