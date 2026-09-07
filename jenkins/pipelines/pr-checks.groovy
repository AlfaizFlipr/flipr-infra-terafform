pipeline {
  agent {
    kubernetes {
      defaultContainer 'tools'
      yaml '''
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: tools
    image: alpine:3.22
    command: ["sleep"]
    args: ["99d"]
'''
    }
  }
  options {
    ansiColor('xterm')
    disableConcurrentBuilds(abortPrevious: true)
    timeout(time: 20, unit: 'MINUTES')
  }
  parameters {
    string(name: 'REPOSITORY', defaultValue: '', description: 'GitHub repository name')
    string(name: 'PR_NUMBER', defaultValue: '', description: 'GitHub pull request number')
    string(name: 'HEAD_SHA', defaultValue: '', description: 'Exact PR head commit')
    string(name: 'HEAD_REF', defaultValue: '', description: 'PR source branch')
    string(name: 'BASE_REF', defaultValue: '', description: 'PR target branch')
  }
  environment {
    GITHUB_ORG = '@@GITHUB_ORG@@'
    GITHUB_TOKEN = credentials('fliprlab-github-token')
  }
  stages {
    stage('Validate event') {
      steps {
        script {
          if (!params.REPOSITORY.trim() || !(params.PR_NUMBER ==~ /[0-9]+/) || !(params.HEAD_SHA ==~ /[0-9a-f]{40}/)) {
            error('REPOSITORY, PR_NUMBER and a 40-character HEAD_SHA are required.')
          }
        }
      }
    }
    stage('Checkout PR commit') {
      steps {
        container('tools') {
          sh '''
            set +x
            set -eu
            apk add --no-cache git
            git config --global --add safe.directory "$WORKSPACE"
            git init .
            git remote add origin "https://github.com/${GITHUB_ORG}/${REPOSITORY}.git"
            if [ -n "${GITHUB_TOKEN:-}" ]; then
              git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${REPOSITORY}.git"
            fi
            git fetch --depth=1 origin "${HEAD_SHA}"
            git checkout --detach FETCH_HEAD
          '''
        }
      }
    }
    stage('PR checks') {
      steps {
        container('tools') {
          sh '''
            set +x
            set -eu
            echo "Running placeholder checks for ${GITHUB_ORG}/${REPOSITORY} PR #${PR_NUMBER}"
            echo "Target: ${BASE_REF}; source: ${HEAD_REF}; commit: ${HEAD_SHA}"
            test -n "$(find . -mindepth 1 -maxdepth 1 ! -name .git -print -quit)"
            git diff-tree --no-commit-id --check -r HEAD
            # Replace/add project-specific lint, test and security commands here.
          '''
        }
      }
    }
  }
  post {
    success { echo "PR #${params.PR_NUMBER} checks passed." }
    failure { echo "PR #${params.PR_NUMBER} checks failed." }
  }
}
