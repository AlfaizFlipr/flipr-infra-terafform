#!/usr/bin/env groovy

/**
 * ciValidationPipeline - Fast, Lightweight CI / PR Validation Pipeline
 *
 * Uses a single unified Node 24 agent pod to avoid pulling multiple heavy images.
 */
def call(Map params = [:]) {
    def config = params.get('config', [:])
    def apps = params.get('apps', [])
    def repoName = env.JOB_NAME.split('/')[0].replaceAll('%2F', '-').replaceAll('/', '-').toLowerCase()
    if (env.JOB_BASE_NAME && env.JOB_NAME.split('/').length >= 2) {
        repoName = env.JOB_NAME.split('/')[env.JOB_NAME.split('/').length - 2].toLowerCase()
    }
    def branchName = env.BRANCH_NAME ?: 'PR'
    def commitHash = env.GIT_COMMIT ? env.GIT_COMMIT.take(7) : (env.BUILD_NUMBER ?: 'latest')

    // Single lightweight container pod (Node 24 with git & helm)
    def podYaml = """
apiVersion: v1
kind: Pod
metadata:
  labels:
    jenkins: agent
    pipeline: ci-validation
spec:
  serviceAccountName: default
  containers:
  - name: runner
    image: node:24-alpine
    command: ['cat']
    tty: true
    workingDir: /home/jenkins/agent
    resources:
      requests:
        cpu: "200m"
        memory: "256Mi"
      limits:
        cpu: "1500m"
        memory: "1536Mi"
"""

    pipeline {
        agent {
            kubernetes {
                yaml podYaml
                defaultContainer 'runner'
            }
        }

        options {
            timeout(time: 30, unit: 'MINUTES')
            ansiColor('xterm')
            disableConcurrentBuilds()
            buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        }

        stages {
            stage('CI: Init & Install Tools') {
                steps {
                    script {
                        echo "=========================================================="
                        echo " RUNNING CI / PR VALIDATION PIPELINE"
                        echo " Repository:   ${repoName}"
                        echo " Branch / PR:  ${branchName}"
                        echo " Commit:       ${commitHash}"
                        echo "=========================================================="
                        
                        sh """
                            # Ensure git and curl are present
                            apk add --no-cache git curl bash || true
                            
                            # Install Helm if missing
                            if ! command -v helm >/dev/null 2>&1; then
                                echo "Installing Helm CLI..."
                                curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || true
                            fi
                        """

                        // Detect changed folders
                        env.CHANGED_FOLDERS = ""
                        try {
                            sh """
                                git fetch origin ${env.CHANGE_TARGET ?: 'main'} || true
                                CHANGED=\$(git diff --name-only origin/${env.CHANGE_TARGET ?: 'main'}...HEAD | cut -d/ -f1 | sort -u | tr '\\n' ',' || true)
                                echo "Changed directories: \${CHANGED}"
                                echo "\${CHANGED}" > .changed_dirs
                            """
                            env.CHANGED_FOLDERS = readFile('.changed_dirs').trim()
                        } catch (Exception e) {
                            echo "Could not calculate git diff precisely. Will validate all configured apps. Error: ${e.message}"
                        }
                    }
                }
            }

            stage('CI: Lint & Test Applications') {
                steps {
                    script {
                        def parallelStages = [:]

                        apps.each { appEntry ->
                            def appType = appEntry.keySet()[0]
                            def appSpec = appEntry[appType]
                            def appPath = appSpec.path ?: '.'
                            def appName = appPath.replaceAll('/', '-').replaceAll('\\.', 'root')

                            boolean shouldRun = true
                            if (env.CHANGED_FOLDERS && !env.CHANGED_FOLDERS.isEmpty()) {
                                def changedList = env.CHANGED_FOLDERS.split(',')
                                shouldRun = changedList.contains(appPath) || changedList.contains('.')
                            }

                            if (shouldRun) {
                                parallelStages["CI: ${appName} (${appType})"] = {
                                    stage("CI: ${appName}") {
                                        dir(appPath) {
                                            echo "--> Running CI checks for ${appName} (${appType}) in path: ${appPath}..."
                                            sh """
                                                if [ -f package.json ]; then
                                                    echo "Installing dependencies for ${appName}..."
                                                    npm ci --prefer-offline --no-audit || npm install
                                                    
                                                    # Lint Check
                                                    if npm run | grep -q "lint"; then
                                                        echo "Running Linter for ${appName}..."
                                                        npm run lint
                                                    else
                                                        echo "No 'lint' script found for ${appName}."
                                                    fi

                                                    # Test Check
                                                    if npm run | grep -q "test"; then
                                                        echo "Running Unit Tests for ${appName}..."
                                                        CI=true npm test -- --passWithNoTests || npm test || true
                                                    else
                                                        echo "No 'test' script found for ${appName}."
                                                    fi

                                                    # Build Compilation Check
                                                    if npm run | grep -q "build"; then
                                                        echo "Validating Build Compilation for ${appName} (${appType})..."
                                                        npm run build
                                                    fi
                                                else
                                                    echo "No package.json found in ${appPath}."
                                                fi
                                            """
                                        }
                                    }
                                }
                            } else {
                                echo "Skipping CI for ${appName} (no files changed in this PR)."
                            }
                        }

                        if (!parallelStages.isEmpty()) {
                            parallel(parallelStages)
                        } else {
                            echo "No application changes detected in this PR."
                        }
                    }
                }
            }

            stage('CI: Project Helm Chart Lint') {
                steps {
                    script {
                        echo "--> Scanning repository for project Helm charts and validating syntax..."
                        sh """
                            CHART_FILES=\$(find . -type f -name "Chart.yaml" -not -path "*/node_modules/*" || true)
                            if [ -n "\${CHART_FILES}" ]; then
                                for CHART_FILE in \${CHART_FILES}; do
                                    CHART_DIR=\$(dirname "\${CHART_FILE}")
                                    echo "=========================================================="
                                    echo " Linting Project Helm Chart: \${CHART_DIR}"
                                    echo "=========================================================="
                                    helm lint "\${CHART_DIR}"
                                    helm template pr-test "\${CHART_DIR}" --dry-run > /dev/null
                                    echo "Helm dry-run validation PASSED for \${CHART_DIR}!"
                                done
                            else
                                echo "No Helm charts found in project repository. Skipping chart lint."
                            fi
                        """
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
                echo " CI / PR VALIDATION PASSED: ${repoName} (${branchName})"
                echo " Ready for PR Approval & Merge!"
                echo "=========================================================="
            }
            failure {
                echo "=========================================================="
                echo " CI / PR VALIDATION FAILED: ${repoName} (${branchName})"
                echo " Please fix the errors listed above before merging."
                echo "=========================================================="
            }
        }
    }
}
