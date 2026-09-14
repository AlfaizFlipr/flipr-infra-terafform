#!/usr/bin/env groovy

/**
 * multipleFolderBuild - Master Dispatcher Pipeline DSL for Flipr Organization
 *
 * Rules:
 * 1. If it's a Pull Request AND the PR comment contains "DEPLOY" -> Runs CD Deployment!
 * 2. If it's a Pull Request (normal commit) -> Runs CI / PR Validation Pipeline!
 * 3. If it's a merge / push to main/dev -> Runs CD Deployment Pipeline!
 */
def call(Map params = [:]) {
    boolean isPullRequest = (env.CHANGE_ID != null || env.CHANGE_TARGET != null || (env.BRANCH_NAME != null && env.BRANCH_NAME.startsWith('PR-')))
    
    // Inspect PR Comment for 'DEPLOY' keyword (supports GitHub PR Builder and Generic Webhook variables)
    String prComment = (env.ghprbCommentBody ?: env.GITHUB_PR_COMMENT ?: "").toUpperCase()
    boolean hasDeployKeyword = prComment.contains('DEPLOY')

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

