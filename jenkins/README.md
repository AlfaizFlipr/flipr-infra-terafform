# Jenkins pipeline design

This directory contains the initial reusable design for two pipelines per project:

- `Jenkinsfile.ci`: validates every pull request and never deploys.
- `Jenkinsfile.deploy`: builds, pushes, and deploys approved commits from `dev`/`develop` or `main`.

Copy both files into each application repository, or configure each Jenkins job to load them from this repository. Keeping them in each application repository is recommended because pipeline changes then follow the same pull-request review process as application changes.

## Flow

```text
Pull request opened/updated
  -> CI / PR Validation
  -> fmt -> validate -> lint -> security -> plan
  -> GitHub required status check
  -> merge allowed only when green

Merged commit containing [deploy]
  -> Deployment Pipeline
  -> develop/dev => Dev
  -> main => Production approval => Prod
  -> build image -> push registry -> kubectl rollout -> verify
```

`[deploy]` must be in the final merge commit message, for example:

```text
[deploy] release payments-api to dev
```

## Jenkins jobs

Create two **Multibranch Pipeline** jobs per project.

### `<project>-pr-validation`

- Branch source: the project's GitHub repository.
- Build strategy: discover pull requests from origin; optionally discover branches.
- Script path: `jenkins/Jenkinsfile.ci` (or `Jenkinsfile.ci` when copied to the repository root).
- Webhook: `http(s)://<jenkins-url>/github-webhook/`.
- GitHub branch protection: require this Jenkins status check before merging.

### `<project>-deploy`

- Branch source: the same GitHub repository.
- Discover branches `develop`/`dev` and `main`; do not deploy pull-request heads.
- Script path: `jenkins/Jenkinsfile.deploy` (or `Jenkinsfile.deploy` at repository root).
- The commit must contain `[deploy]`.
- `develop` or `dev` deploys to Dev.
- `main` pauses for a member of the Jenkins `infra-admins` group.

GitHub branch protection—not the Jenkinsfile—enforces that a PR cannot merge until CI succeeds. Configure this in GitHub under **Settings -> Branches/Rulesets -> Require status checks**.

## Required Jenkins plugins

- Pipeline and Pipeline: Declarative
- Git
- GitHub Branch Source
- Credentials Binding
- Kubernetes (when builds use Kubernetes agents)
- ANSI Color

## Credentials

Create these in **Manage Jenkins -> Credentials**:

- `github-app`: GitHub App credential with repository metadata read, contents read, pull requests read, and commit statuses read/write.
- `k3s-kubeconfig`: Secret file containing a restricted deployment kubeconfig. Do not use the cluster-admin kubeconfig for production.
- Registry credentials should be added as `registry-credentials` when authentication is enabled. The current internal registry is unauthenticated, so it is suitable only for a trusted development network.

Never put tokens, passwords, kubeconfig contents, or registry credentials in a Jenkinsfile or repository.

## Agent contract

The initial pipelines use the Jenkins label `infra-tools`. The matching agent must provide:

- `git`, `terraform`, `tflint`, `trivy`
- `docker` with permission to build and push images
- `kubectl`
- network/DNS access to `docker-registry.registry.svc.cluster.local:5000`

For production, replace Docker socket access with a rootless builder such as BuildKit or Kaniko, and enable TLS/authentication on the registry.

## Per-project conventions

Each application repository should contain:

- `Dockerfile`
- a Kubernetes Deployment whose deployment name and container name match `APP_NAME`
- environment configuration/manifests for Dev and Prod
- Terraform files when infrastructure validation is required

Set `APP_NAME` and `K8S_NAMESPACE` in the deployment job. The basic deploy stage updates an existing Deployment with `kubectl set image`; a later version can replace this with Helm or Kustomize.

## Important limitation

These files define the pipeline behavior, but GitHub webhooks, branch-protection rules, Jenkins credentials, the `infra-admins` group, and the `infra-tools` agent require administrator configuration. Production deployment remains blocked until those controls are configured.
