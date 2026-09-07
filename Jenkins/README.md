# Jenkins GitHub Organization PR pipelines

This repository has two independent Jenkinsfiles. Do **not** use a single
Organization Folder for both: Jenkins' GitHub Organization Folder accepts one
script path per discovered repository. Create two folders, each connected to
the same GitHub organization:

| Jenkins folder | Script Path | Role |
| --- | --- | --- |
| `PR Validation` | `Jenkins/pr-validation/Jenkinsfile` | required PR checks |
| `Test Deploy` | `Jenkins/deploy-test/Jenkinsfile` | downstream test-image build |

## One-time Jenkins configuration

The repeatable folder setup is available as `Jenkins/setup-org-folders.sh`.
It creates/updates both folders using the Jenkins API after the required
credentials have been created. It never stores credentials in Git.

1. Install/update these plugins: **GitHub Branch Source**, **Pipeline**,
   **Credentials Binding**, **Warnings Next Generation** (optional), **JUnit**,
   **AnsiColor**, and the agent plugin you use
   (Kubernetes or Docker).
2. Configure **Manage Jenkins → Configure System → Global Pipeline Libraries**:
   add `ms-jenkins-global-lib`, using its Git repository and trusted default
   version. The annotation in both Jenkinsfiles intentionally uses that library.
3. Provide disposable Jenkins agents labelled `terraform-ci` and
   `kubernetes-ci`. The first needs `git`, Terraform, `tflint`, `trivy`,
   and `gitleaks`. The second needs `git` and a Docker daemon
   that can reach the internal registry. Do not put production cloud credentials
   on either PR agent.
4. In Jenkins, create an **Organization Folder** called `PR Validation`.
   Under **Projects → Repository Sources**, add **GitHub Organization**. Select
   a GitHub App (recommended) or token credential and enter `flipr-Infra-test`
   as the owner — not the full URL. Set **Build Configuration → Script Path** to
   `Jenkins/pr-validation/Jenkinsfile`. In **Behaviours**, enable pull-request
   discovery for both origin and fork PRs as appropriate; for untrusted forks,
   build the merge revision and restrict secrets.
5. Create a second Organization Folder called `Test Deploy`, with the same
   GitHub Organization source and credentials. Set its Script Path to
   `Jenkins/deploy-test/Jenkinsfile`. Give this folder an explicit permission
   allowing `PR Validation` to build its child jobs.
6. Run **Scan Organization Now** on both folders once. Configure the GitHub App
   webhook to Jenkins' externally reachable webhook endpoint (not
   `127.0.0.1`) so PR open/synchronize events rescan promptly. The GitHub App
   needs repository metadata, contents read, pull requests read, and checks
   read/write permissions.

## Required merge protection

On GitHub, add a branch protection/ruleset for protected branches. Require pull
requests, require status checks to pass, and select the check reported by
`PR Validation` (the exact context appears after its first run). Also require
the branch to be up to date before merging and restrict who can dismiss review
or bypass the rule. Do **not** make `Test Deploy` required: it only runs when a
validated PR has an exact commit subject of `deploy`.

## Execution flow

`PR Validation` runs every PR creation/update. When it succeeds, it searches
the PR-only commits for a commit subject exactly equal to `deploy` (case
insensitive). If found, it starts the matching `Test Deploy/<repo>/PR-<id>` job.
That downstream job refuses manual/webhook-only runs, builds and pushes a
test-tagged image, runs a smoke test, archives artifacts, and exposes all stage
logs in Jenkins. Production remains disabled unless a main-branch production
run explicitly sets `DEPLOY_PRODUCTION=true`; then only members of
`jenkins-prod-approvers` can approve it.

The internal registry installed by this Terraform project currently permits
anonymous push by default. Before using the pattern beyond isolated testing,
enable registry authentication/TLS and replace `TEST_REGISTRY` with its secure
endpoint.
