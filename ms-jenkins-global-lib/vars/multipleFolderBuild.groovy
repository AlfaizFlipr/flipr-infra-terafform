#!/usr/bin/env groovy

/**
 * multipleFolderBuild - Master Dispatcher Pipeline DSL for Flipr Organization
 *
 * Rules:
 * 1. If it's a Pull Request AND the commit message contains "deploy" -> Runs CD Deployment!
 * 2. If it's a Pull Request (normal commit) -> Runs CI / PR Validation Pipeline!
 * 3. If it's a merge / push to main/dev -> Runs CD Deployment Pipeline!
 */
def call(Map params = [:]) {
    boolean isPullRequest = (env.CHANGE_ID != null || env.CHANGE_TARGET != null)
    
    // Check if commit message contains "deploy" (case-insensitive)
    String commitMsg = ""
    try {
        commitMsg = sh(script: 'git log -1 --pretty=%B || true', returnStdout: true).trim().toLowerCase()
    } catch (Exception e) {
        commitMsg = ""
    }

    boolean hasDeployKeyword = commitMsg.contains('deploy')

    echo "=========================================================="
    echo " Execution Mode Decision:"
    echo " Is Pull Request:    ${isPullRequest}"
    echo " Commit Message:     ${commitMsg}"
    echo " Has 'deploy' word:  ${hasDeployKeyword}"
    echo "=========================================================="

    if (isPullRequest && !hasDeployKeyword) {
        echo "--> Triggering CI / PR Validation Pipeline for PR commit..."
        ciValidationPipeline(params)
    } else {
        echo "--> Triggering CD / Deployment Pipeline (Approved Deploy / Merge)..."
        cdDeploymentPipeline(params)
    }
}
