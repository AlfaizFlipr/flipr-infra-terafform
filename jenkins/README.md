# Flipr Labs Jenkins PR pipelines

This setup creates the following branch-oriented hierarchy:

```text
FLIPRLABS/<repository>/pull-request-checker/<PR source branch>
FLIPRLABS/<repository>/pull-request-deploy/<PR source branch>
```

The dispatcher creates branch-named jobs for every open PR. A new or updated PR
runs its job below `pull-request-checker`. A new PR comment whose complete text
is `/deploy` runs the matching branch job below `pull-request-deploy`; it builds
the exact PR commit, pushes a test image, and applies a disposable placeholder
deployment in the `ci-preview` namespace. Branch characters unsupported by
Jenkins job names (for example `/`) are replaced with `-`.

If migrating from the older top-level `pr-checks`/`deploy` layout, remove only
those legacy Jenkins folders after the nested setup succeeds:

```bash
bash jenkins/cleanup-legacy-jobs.sh
```

The `pipeline-graph-view` plugin provides **Pipeline Overview** on each build
page. Open an individual build such as `project/pr-checks #1`, then select
**Pipeline Overview**; Jenkins does not show that link on the project folder page.

## Test-only safety boundary

This setup treats GitHub as read-only. It never posts a PR status, writes a PR
comment, adds a label, pushes a branch/tag, merges a PR, creates a release, or
changes repository settings. The token should have read-only permissions only.
The deploy job deliberately ignores every repository-provided Dockerfile and
builds a Jenkins-generated nginx test image, so code supplied by a PR is not
executed during this infrastructure test.

`FLIPRLABS/github-pr-dispatcher` polls GitHub every five minutes. Polling is
intentional because this Jenkins service is only reachable at localhost and a
GitHub webhook cannot call it. State is stored on the Jenkins persistent volume,
so the same SHA/comment is not dispatched twice. Existing historic `/deploy`
comments are recorded but not executed on the first dispatcher run.

All three pipeline types run on disposable Kubernetes agent Pods in the
`jenkins` namespace, not on the Jenkins controller. Each Pod is removed after
its build. With the current single-node K3s cluster those Pods necessarily run
on `flipr-vm-optiplex-7040`; add and label a worker node before pinning CI to a
separate physical machine.

## 1. Configure repositories and token

Edit `repositories.txt`. Private repositories are not visible through GitHub's
anonymous organization API, so the file is the source of truth.

In Jenkins, create this credential:

1. **Manage Jenkins > Credentials > System > Global credentials > Add Credentials**
2. Kind: **Secret text**
3. Secret: a fine-grained GitHub token with **read-only** access to repository
   Contents, Metadata, Pull requests, and Issues (comments are issue comments).
   Do not grant any write permission.
4. ID: `fliprlab-github-token`

Copy optional settings:

```bash
cp jenkins/config.env.example jenkins/config.env
```

Do not commit `config.env` when it contains a token. The setup script never
needs the token itself; Jenkins reads it from its credential store at runtime.

## 2. Create or update all jobs

Keep the local Jenkins port-forward running, then execute:

```bash
bash jenkins/setup.sh
```

The command is idempotent: rerunning it updates managed folder/job XML. It also
creates `ci-preview` and grants the Jenkins service account a restricted Role
for preview deployments and dispatcher state only in that namespace.

Start `FLIPRLABS/github-pr-dispatcher` once with **Build Now**. Its cron trigger
is installed when that first build starts; after that it polls automatically.

## Pipeline behaviour

The check job verifies a real checkout of the immutable PR head SHA and rejects
Git whitespace errors without running project code. The deploy job always builds
a Jenkins-generated nginx placeholder image and never uses a Dockerfile from the
repository. Image tags have the form `pr-<number>-<short-sha>`. Because the
current K3s installation has no insecure-registry mirror configuration, the
dummy deployment runs public nginx and records the built internal image in the
`fliprlabs.io/built-image` annotation. After registry TLS (recommended) is
enabled, change the deployment image to `$IMAGE`.

To redeploy the same PR commit, add a new `/deploy` comment. Editing or reusing
an old comment does not retrigger it because the GitHub comment ID is the
idempotency key.

## Production follow-ups

- Replace the placeholder checks in `pipelines/pr-checks.groovy` with each
  project's test/lint commands (or route by repository name).
- Replace the dummy deployment with Helm/Kustomize manifests and use a narrower
  Kubernetes Role than namespace admin.
- Enable Jenkins authentication before exposing it beyond localhost.
- Use a trusted certificate and registry authentication before using this
  registry outside the cluster.
