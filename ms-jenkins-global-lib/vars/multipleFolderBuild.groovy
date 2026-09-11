#!/usr/bin/env groovy

/**
 * multipleFolderBuild - Master Dispatcher Pipeline DSL for Flipr Organization
 *
 * Checks PR title, branch name, and commit message for "deploy" keyword:
 * 1. If PR title or branch contains "deploy" -> CD Deployment Pipeline
 * 2. If it's a standard PR -> CI / PR Validation Pipeline
 * 3. If it's a push/merge to main/dev -> CD Deployment Pipeline
 */
def call(Map params = [:]) {
    boolean isPullRequest = (env.CHANGE_ID != null || env.CHANGE_TARGET != null)
    
    // Check environment variables for deploy trigger (PR title, branch name)
    String changeTitle = (env.CHANGE_TITLE ?: '').toLowerCase()
    String branchName = (env.BRANCH_NAME ?: '').toLowerCase()
    String changeBranch = (env.CHANGE_BRANCH ?: '').toLowerCase()

    boolean isDeployTrigger = changeTitle.contains('deploy') || 
                              branchName.contains('deploy') || 
                              changeBranch.contains('deploy')

    echo "=========================================================="
    echo " Execution Mode Decision:"
    echo " Is Pull Request:      ${isPullRequest}"
    echo " PR Title:             ${env.CHANGE_TITLE ?: 'N/A'}"
    echo " Branch Name:          ${env.BRANCH_NAME ?: 'N/A'}"
    echo " Deploy Keyword Found: ${isDeployTrigger}"
    echo "=========================================================="

    if (isPullRequest && !isDeployTrigger) {
        echo "--> Triggering CI / PR Validation Pipeline for PR..."
        ciValidationPipeline(params)
    } else {
        echo "--> Triggering CD / Deployment Pipeline..."
        cdDeploymentPipeline(params)
    }
}
