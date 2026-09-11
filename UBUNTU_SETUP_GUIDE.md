# Complete A-to-Z Guide: Jenkins Organization Pipeline, Shared Library, In-Cluster Registry & Argo Rollouts on Ubuntu

This comprehensive guide walks you through setting up the complete CI/CD & GitOps stack on your Ubuntu machine (`flipr-vm-OptiPlex-7040`) for the GitHub Organization **`flipr-Infra-test`**.

---

## Architecture Summary

```
+----------------------------------------------------------------------------------------------------+
|  GitHub Organization: https://github.com/flipr-Infra-test                                          |
|  - All Project Repositories (e.g. playedx, knowledge-ai, etc.)                                     |
|  - Contains: Jenkinsfile (@Library('ms-jenkins-global-lib') _) + Project Helm Chart in repo        |
+-------------------------------------------------+--------------------------------------------------+
                                                  | Webhook (PR / Push)
                                                  v
+----------------------------------------------------------------------------------------------------+
|  Jenkins (jenkins-0 in Kubernetes)                                                                 |
|  - GitHub Organization Job: Automatically discovers all repos in flipr-Infra-test                  |
|  - Shared Library: ms-jenkins-global-lib (vars/multipleFolderBuild.groovy)                         |
|  - Dynamic K8s Agent Pod: nodejs (Node 24) + kaniko (Image Builder) + helm-kubectl                 |
+------------------------+---------------------------------------------------+-----------------------+
                         |                                                   |
                         v (CI Mode: PR)                                     v (CD Mode: Merge)
+---------------------------------------------------+  +---------------------------------------------+
|  Pipeline 1: CI / PR Validation                   |  |  Pipeline 2: CD / Deployment                |
|  - Detects changed folders                        |  |  1. Kaniko builds Docker images             |
|  - Parallel lint & test (api, web, admin)         |  |  2. Pushes to internal Docker Registry     |
|  - Project Helm chart lint & dry-run              |  |     docker-registry.registry.svc:5000       |
|  - Reports PASS/FAIL check back to GitHub PR      |  |  3. Deploys project's Helm chart           |
+---------------------------------------------------+  |  4. Manages Argo Rollouts Canary Release    |
                                                       +---------------------+-----------------------+
                                                                             |
                                                                             v
+----------------------------------------------------------------------------------------------------+
|  Kubernetes Workloads & Traffic Management                                                         |
|  - Argo Rollouts: 20% traffic -> Health pause -> 50% traffic -> Health pause -> 100% stable        |
|  - Argo Rollouts Dashboard UI: Live visual traffic splitting & manual promotion                     |
|  - Argo CD: Cluster GitOps & application synchronization                                           |
+----------------------------------------------------------------------------------------------------+
```

---

## STEP 1: Install Argo CD & Argo Rollouts Stack on Ubuntu

On your Ubuntu machine (`flipr-vm@flipr-vm-OptiPlex-7040`), run the automated installation script:

```bash
cd "terraform Infra"
chmod +x kubernetes/scripts/install-argo-stack.sh
./kubernetes/scripts/install-argo-stack.sh
```

Or run the commands manually:

```bash
# 1. Create Namespaces
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -

# 2. Install Argo CD (Server-side apply avoids CRD annotation size limit)
kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 3. Install Argo Rollouts Controller & CRDs (Server-side apply)
kubectl apply --server-side --force-conflicts -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# 4. Install Argo Rollouts Dashboard UI
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/dashboard-install.yaml

# 5. Install kubectl-argo-rollouts CLI Plugin
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x ./kubectl-argo-rollouts-linux-amd64
sudo mv ./kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts

# 6. Apply Ingress routes for all Dashboards
kubectl apply -f kubernetes/manifests/argo-cd/argocd-ingress.yaml
kubectl apply -f kubernetes/manifests/argo-rollouts/rollouts-dashboard-ingress.yaml
kubectl apply -f kubernetes/manifests/ingress-routes/jenkins-ingress.yaml
kubectl apply -f kubernetes/manifests/ingress-routes/registry-ingress.yaml
```

### Configure Local Hostnames (`/etc/hosts`)
Find your MetalLB Ingress IP (`kubectl get svc -n kube-system` or `kubectl get svc traefik -n kube-system`):
```bash
# Example: If your MetalLB / node IP is 192.168.1.100 (or kube-vip IP):
sudo bash -c 'cat << EOF >> /etc/hosts
127.0.0.1 jenkins.flipr.local
127.0.0.1 argocd.flipr.local
127.0.0.1 rollouts.flipr.local
127.0.0.1 registry.flipr.local
EOF'
```

### Access Dashboards:
| Dashboard | URL | Credentials |
| :--- | :--- | :--- |
| **Jenkins Web UI** | `http://jenkins.flipr.local` (or `http://<NODE_IP>:8080` via port-forward) | `admin` / your Jenkins admin password |
| **Argo Rollouts Dashboard** | `http://rollouts.flipr.local` (or `kubectl argo rollouts dashboard -n argo-rollouts`) | No login required (Visual traffic control) |
| **Argo CD UI** | `http://argocd.flipr.local` | `admin` / Password retrieved via: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" \| base64 -d` |

---

## STEP 2: Configure Jenkins Global Shared Library (`ms-jenkins-global-lib`)

1. Open Jenkins: `http://jenkins.flipr.local` (or port 8080).
2. Go to **Manage Jenkins** -> **System**.
3. Scroll down to **Global Pipeline Libraries** and click **Add**:
   - **Name**: `ms-jenkins-global-lib`
   - **Default version**: `main`
   - **Retrieval method**: Select **Modern SCM** -> **Git**.
   - **Project Repository**: `https://github.com/AlfaizFlipr/flipr-infra-terafform.git` (or the repo containing `ms-jenkins-global-lib/`).
   - **Credentials**: Select your GitHub credentials.
   - **Library Path**: `ms-jenkins-global-lib` (if inside this repo) or leave blank if in a dedicated repo root.
4. Click **Save**.

---

## STEP 3: Configure GitHub Credentials & Create Organization Pipeline in Jenkins

### 1. Generate GitHub Personal Access Token (PAT)
1. In GitHub, go to **Settings** -> **Developer Settings** -> **Personal Access Tokens (Tokens classic)**.
2. Generate new token with scopes:
   - `repo` (Full control of private repositories)
   - `admin:repo_hook` (Full control of repository hooks)
   - `read:org` (Read organization data)
3. Copy the token.

### 2. Add Credentials in Jenkins
1. Go to **Manage Jenkins** -> **Credentials** -> **System** -> **Global credentials (unrestricted)**.
2. Click **Add Credentials**:
   - **Kind**: `Username with password` (or `Secret text`).
   - **Username**: Your GitHub username.
   - **Password**: Paste your GitHub PAT token.
   - **ID**: `github-org-token`.
   - **Description**: `Flipr GitHub Organization Token`.
3. Click **Create**.

### 3. Create GitHub Organization Job in Jenkins
1. On Jenkins Dashboard, click **New Item**.
2. Enter Name: `flipr-Infra-test`.
3. Select **GitHub Organization** and click **OK**.
4. In Configuration:
   - **Projects** -> **GitHub Organization**:
     - **Credentials**: Select `github-org-token`.
     - **Owner**: `flipr-Infra-test` (or `https://github.com/flipr-Infra-test`).
   - **Behaviors**:
     - **Discover branches**: `Exclude branches that are also filed as PRs`
     - **Discover pull requests from origin**: `The current pull request revision`
     - **Discover pull requests from forks**: `The current pull request revision`
   - **Scan Organization Triggers**: Check `Periodically if not otherwise run` -> Interval: `1 hour`.
5. Click **Save**. Jenkins will immediately scan `flipr-Infra-test` and automatically discover all project repositories!

---

## STEP 4: Configure GitHub Organization Webhook

To enable instant automatic triggers when a PR is opened or code is pushed:

1. In GitHub, go to: `https://github.com/organizations/flipr-Infra-test/settings/hooks`.
2. Click **Add webhook**:
   - **Payload URL**: `http://<YOUR_JENKINS_PUBLIC_URL_OR_DOMAIN>/github-webhook/`
   - **Content type**: `application/json`
   - **Which events would you like to trigger this webhook?**: Select **Send me everything** (or Pull requests + Pushes).
3. Click **Add webhook**.

---

## STEP 5: How Project Repositories Look (`flipr-Infra-test`)

Inside each application repository in your organization (e.g. `playedx` or any other project):

### 1. Root `Jenkinsfile`
Create `Jenkinsfile` in the root of the project repository:

```groovy
@Library('ms-jenkins-global-lib') _

multipleFolderBuild(
    config: [
        domainWith: "subdomain",
        apiPath: "api",
        volumes: [uploads:[]]
    ],
    apps: [
        [
            nodeJs: [
                path: "api",
                node_version: '24',
                volumes: ["uploads:/app/uploads"]
            ]
        ],
        [
            reactJs: [
                path: "web",
                node_version: '24'
            ]
        ],
        [
            reactJs: [
                path: "admin",
                node_version: '24'
            ]
        ],
        [
            reactJs: [
                path: "college",
                node_version: '24'
            ]
        ],        
        [
            reactJs: [
                path: "question-manager",
                node_version: '24'
            ]
        ]
    ]
)
```

### 2. Project Helm Chart Inside Project Repo
Following the standard `knowledge-ai` pattern, put the Helm chart inside each app directory or in `helm/`:

```
my-project-repo/
├── Jenkinsfile
├── api/
│   ├── Dockerfile
│   ├── package.json
│   └── helm/
│       └── api-chart/
│           ├── Chart.yaml
│           ├── values.yaml
│           └── templates/
│               ├── rollout.yaml         # Argo Rollout Canary Template
│               ├── service.yaml
│               └── ingress.yaml
└── web/
    ├── Dockerfile
    ├── package.json
    └── helm/
        └── web-chart/
            ├── Chart.yaml
            ├── values.yaml
            └── templates/
                ├── rollout.yaml
                ├── service.yaml
                └── ingress.yaml
```

#### Example `templates/rollout.yaml` in Project Helm Chart:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: {{ .Release.Name }}
  namespace: {{ .Release.Namespace }}
spec:
  replicas: 3
  revisionHistoryLimit: 5
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      containers:
      - name: app
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: {{ .Values.service.targetPort | default 3000 }}
  strategy:
    canary:
      canaryService: {{ .Release.Name }}-canary
      stableService: {{ .Release.Name }}-stable
      trafficRouting:
        nginx:
          stableIngress: {{ .Release.Name }}-ingress
      steps:
      - setWeight: 20
      - pause: { duration: 30s }
      - setWeight: 50
      - pause: { duration: 30s }
      - setWeight: 100
```

---

## STEP 6: End-to-End Verification & Rollout Management

### 1. Test CI Pipeline (Pull Request)
1. Create a new branch in a project repository: `git checkout -b feature/test-ci`.
2. Make a small code change in `web/` or `api/`.
3. Push branch and open a **Pull Request** to `main` on GitHub.
4. **Result**:
   - Jenkins immediately detects the PR webhook.
   - Runs `CI / PR Validation`: Detects modified folder, runs Node 24 linting & tests, and performs `helm lint` on the project's Helm chart.
   - Posts a green checkmark status to GitHub PR: `continuous-integration/jenkins/pr-head: SUCCESS`.

### 2. Test CD Pipeline & Canary Deployment (Merge)
1. Merge the approved Pull Request into `main`.
2. **Result**:
   - Jenkins triggers the **CD Deployment Pipeline**.
   - Kaniko builds the container image in-cluster and pushes it to `docker-registry.registry.svc.cluster.local:5000/<repo>-<app>:<commit-hash>`.
   - Executes `helm upgrade --install` with the project's own Helm chart.
   - Argo Rollouts initiates the Canary deployment:
     - 20% traffic routed to the new canary version.
     - 30-second observation pause.
     - 50% traffic shifted to canary.
     - 100% promoted to stable.

### 3. Visual Traffic Control via Argo Rollouts Dashboard UI
1. Open the Argo Rollouts Dashboard: `http://rollouts.flipr.local`
2. You will see all your active monorepo applications, their live pods, and traffic percentage split between stable and canary versions.
3. You can click **Promote**, **Pause**, or **Abort/Rollback** directly from the UI!

### CLI Monitoring:
```bash
# View rollout status
kubectl argo rollouts get rollout <release-name> --watch

# Promote manually if paused
kubectl argo rollouts promote <release-name>

# Abort rollout instantly in case of issues
kubectl argo rollouts abort <release-name>
```
