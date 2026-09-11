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
    boolean isPullRequest = (env.CHANGE_ID != null || env.CHANGE_TARGET != null || (env.BRANCH_NAME != null && env.BRANCH_NAME.startsWith('PR-')))
    
    // Safely inspect PR Title, Source Branch, and Branch Name for 'deploy' keyword
    String prTitle = (env.CHANGE_TITLE ?: "").toLowerCase()
    String changeBranch = (env.CHANGE_BRANCH ?: "").toLowerCase()
    String branchName = (env.BRANCH_NAME ?: "").toLowerCase()

    boolean hasDeployKeyword = prTitle.contains('deploy') || changeBranch.contains('deploy') || branchName.contains('deploy')

    echo "=========================================================="
    echo " FLIPR PIPELINE MASTER DISPATCHER"
    echo " Is Pull Request:      ${isPullRequest}"
    echo " Branch Name:          ${env.BRANCH_NAME}"
    echo " PR ID:                ${env.CHANGE_ID ?: 'N/A'}"
    echo " PR Title:             ${env.CHANGE_TITLE ?: 'N/A'}"
    echo " PR Source Branch:     ${env.CHANGE_BRANCH ?: 'N/A'}"
    echo " Deploy Keyword Found: ${hasDeployKeyword}"
    echo "=========================================================="

    if (isPullRequest && !hasDeployKeyword) {
        echo "--> Triggering CI / PR Validation Pipeline (CI Mode)..."
        ciValidationPipeline(params)
    } else {
        echo "--> Triggering CD / Deployment Pipeline (CD Mode: Approved Deploy / Main)..."
        cdDeploymentPipeline(params)
    }
}

