#!/usr/bin/env groovy

/**
 * cdDeploymentPipeline - Dedicated CD / Deployment & Argo Rollouts Pipeline DSL
 *
 * Supports:
 * - nodeJs (APIs / backend)
 * - reactJs (Frontend SPAs)
 * - nextJs (Next.js SSR / Standalone)
 * - Daemonless container image builds with Kaniko
 * - Pushes to internal Docker Registry (docker-registry.registry.svc.cluster.local:5000)
 * - Deploys via project's own Helm charts (e.g. frontend/helm/..., api/helm/..., or helm/)
 * - Tracks Argo Rollouts Canary release progression & live traffic splitting
 */
def call(Map params = [:]) {
    def config = params.get('config', [:])
    def apps = params.get('apps', [])
    def clusterRegistry = params.get('registry', 'docker-registry.registry.svc.cluster.local:5000')
    def releaseNamespace = params.get('namespace', 'default')

    def repoName = env.JOB_NAME.split('/')[0].replaceAll('%2F', '-').replaceAll('/', '-').toLowerCase()
    if (env.JOB_BASE_NAME && env.JOB_NAME.split('/').length >= 2) {
        repoName = env.JOB_NAME.split('/')[env.JOB_NAME.split('/').length - 2].toLowerCase()
    }
    def branchName = env.BRANCH_NAME ?: 'main'
    def commitHash = env.GIT_COMMIT ? env.GIT_COMMIT.take(7) : (env.BUILD_NUMBER ?: 'latest')

    def podYaml = """
apiVersion: v1
kind: Pod
metadata:
  labels:
    jenkins: agent
    pipeline: cd-deployment
spec:
  serviceAccountName: default
  containers:
  - name: kaniko
    image: gcr.io/kaniko-project/executor:debug
    command: ['cat']
    tty: true
    workingDir: /home/jenkins/agent
    securityContext:
      runAsUser: 0
    resources:
      requests:
        cpu: "500m"
        memory: "512Mi"
      limits:
        cpu: "2000m"
        memory: "2048Mi"
  - name: helm-kubectl
    image: alpine/k8s:1.30.2
    command: ['cat']
    tty: true
    workingDir: /home/jenkins/agent
    resources:
      requests:
        cpu: "200m"
        memory: "256Mi"
      limits:
        cpu: "1000m"
        memory: "1024Mi"
"""

    pipeline {
        agent {
            kubernetes {
                yaml podYaml
                defaultContainer 'kaniko'
            }
        }

        options {
            timeout(time: 60, unit: 'MINUTES')
            ansiColor('xterm')
            disableConcurrentBuilds()
            buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        }

        stages {
            stage('CD: Build & Push Images (Kaniko)') {
                steps {
                    script {
                        echo "=========================================================="
                        echo " RUNNING CD / DEPLOYMENT PIPELINE"
                        echo " Repository:   ${repoName}"
                        echo " Branch:       ${branchName}"
                        echo " Commit:       ${commitHash}"
                        echo " Apps:         ${apps.size()} configured"
                        echo "=========================================================="

                        apps.each { appEntry ->
                            def appType = appEntry.keySet()[0]
                            def appSpec = appEntry[appType]
                            def appPath = appSpec.path ?: '.'
                            def subAppName = appPath.replaceAll('/', '-').replaceAll('\\.', 'root')
                            def imageRepo = "${clusterRegistry}/${repoName}-${subAppName}"
                            def commitTag = "${imageRepo}:${commitHash}"
                            def latestTag = "${imageRepo}:latest"

                            stage("Build: ${subAppName}") {
                                container('kaniko') {
                                    echo "--> Kaniko Building Docker image for ${subAppName} (${appType})..."
                                    dir(appPath) {
                                        sh """
                                            # Generate Dockerfile if missing (Optimized for NodeJS, ReactJS, NextJS)
                                            if [ ! -f Dockerfile ]; then
                                                echo "Generating Dockerfile for ${appType}..."
                                                if [ "${appType}" = "nextJs" ]; then
                                                    cat << 'EOF' > Dockerfile
FROM node:24-alpine AS base
WORKDIR /app
COPY package*.json ./
RUN npm ci --prefer-offline --no-audit || npm install
COPY . .
RUN npm run build
EXPOSE 3000
CMD ["npm", "start"]
EOF
                                                elif [ "${appType}" = "reactJs" ]; then
                                                    cat << 'EOF' > Dockerfile
FROM node:24-alpine AS base
WORKDIR /app
COPY package*.json ./
RUN npm ci --prefer-offline --no-audit || npm install
COPY . .
RUN if npm run | grep -q "build"; then npm run build; fi
EXPOSE 3000 80
CMD ["npm", "start"]
EOF
                                                else
                                                    cat << 'EOF' > Dockerfile
FROM node:24-alpine AS base
WORKDIR /app
COPY package*.json ./
RUN npm ci --prefer-offline --no-audit || npm install
COPY . .
EXPOSE 3000 8080
CMD ["npm", "start"]
EOF
                                                fi
                                            fi

                                            # Build and push directly to in-cluster Docker Registry without Docker daemon
                                            /kaniko/executor \
                                                --context=dir://. \
                                                --dockerfile=Dockerfile \
                                                --destination=${commitTag} \
                                                --destination=${latestTag} \
                                                --insecure \
                                                --skip-tls-verify \
                                                --cache=true \
                                                --cache-dir=/tmp/kaniko-cache
                                            
                                            echo "Successfully pushed ${commitTag} to local registry!"
                                        """
                                    }
                                }
                            }
                        }
                    }
                }
            }

            stage('CD: Deploy Project Helm Charts') {
                steps {
                    container('helm-kubectl') {
                        script {
                            echo "--> Deploying applications using project Helm chart(s)..."
                            sh "kubectl create namespace ${releaseNamespace} --dry-run=client -o yaml | kubectl apply -f -"

                            apps.each { appEntry ->
                                def appType = appEntry.keySet()[0]
                                def appSpec = appEntry[appType]
                                def appPath = appSpec.path ?: '.'
                                def subAppName = appPath.replaceAll('/', '-').replaceAll('\\.', 'root')
                                def releaseName = "${repoName}-${subAppName}"
                                def imageRepository = "${clusterRegistry}/${releaseName}"
                                def imageTag = commitHash

                                stage("Deploy: ${releaseName}") {
                                    sh """
                                        # Locate the Helm chart for this app
                                        CHART_PATH=""
                                        if [ -f "${appPath}/helm/Chart.yaml" ]; then
                                            CHART_PATH="${appPath}/helm"
                                        elif [ -d "${appPath}/helm" ]; then
                                            CHART_PATH=\$(find "${appPath}/helm" -maxdepth 2 -name "Chart.yaml" -exec dirname {} \\; | head -n 1)
                                        elif [ -f "helm/Chart.yaml" ]; then
                                            CHART_PATH="helm"
                                        elif [ -d "helm" ]; then
                                            CHART_PATH=\$(find helm -maxdepth 2 -name "Chart.yaml" -exec dirname {} \\; | head -n 1)
                                        fi

                                        if [ -n "\${CHART_PATH}" ] && [ -f "\${CHART_PATH}/Chart.yaml" ]; then
                                            echo "=========================================================="
                                            echo " Deploying Release: \${releaseName}"
                                            echo " Using Project Chart: \${CHART_PATH}"
                                            echo " Image: ${imageRepository}:${imageTag}"
                                            echo "=========================================================="

                                            helm upgrade --install \${releaseName} "\${CHART_PATH}" \
                                                --namespace ${releaseNamespace} \
                                                --set image.repository=${imageRepository} \
                                                --set image.tag=${imageTag} \
                                                --set app.name=\${releaseName} \
                                                --set app.subdomain=${subAppName} \
                                                --set ingress.hosts[0].host="${subAppName}.${repoName}.flipr.local" \
                                                --wait --timeout 5m

                                            echo "Helm release \${releaseName} applied successfully!"
                                        else
                                            echo "WARNING: No Helm chart found in ${appPath}/helm or ./helm for \${releaseName}."
                                        fi
                                    """
                                }
                            }
                        }
                    }
                }
            }

            stage('CD: Track Argo Rollouts Status') {
                steps {
                    container('helm-kubectl') {
                        script {
                            echo "--> Checking Argo Rollouts deployment progression..."
                            apps.each { appEntry ->
                                def appType = appEntry.keySet()[0]
                                def appSpec = appEntry[appType]
                                def appPath = appSpec.path ?: '.'
                                def subAppName = appPath.replaceAll('/', '-').replaceAll('\\.', 'root')
                                def releaseName = "${repoName}-${subAppName}"

                                sh """
                                    if kubectl get rollout ${releaseName} -n ${releaseNamespace} >/dev/null 2>&1; then
                                        echo "Tracking Argo Rollout for ${releaseName}..."
                                        kubectl argo rollouts status rollout ${releaseName} -n ${releaseNamespace} --timeout=180s || true
                                    fi
                                """
                            }
                        }
                    }
                }
            }
        }

        post {
            always {
                deleteDir()
            }
            success {
                echo "=========================================================="
                echo " CD DEPLOYMENT COMPLETED SUCCESSFULLY!"
                echo " Repository: ${repoName} (${branchName})"
                echo " View Canary Status: https://rollouts.flipr.local"
                echo "=========================================================="
            }
            failure {
                echo "=========================================================="
                echo " CD DEPLOYMENT FAILED: ${repoName} (${branchName})"
                echo " Check logs above for details."
                echo "=========================================================="
            }
        }
    }
}
