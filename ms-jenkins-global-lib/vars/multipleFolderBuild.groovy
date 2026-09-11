#!/usr/bin/env groovy

def call(Map params = [:]) {
    boolean isPullRequest = (env.CHANGE_ID != null || env.CHANGE_TARGET != null)

    if (isPullRequest) {
        echo "--> Triggering CI / PR Validation Pipeline..."
        ciValidationPipeline(params)
    } else {
        echo "--> Triggering CD / Deployment Pipeline..."
        cdDeploymentPipeline(params)
    }
}
