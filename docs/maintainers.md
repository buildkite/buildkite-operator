# Maintainers

## Development

```bash
make test-helm        # lint and render the standalone chart
make helm-examples    # update the chart's rendered examples
make test-supervisor  # run the ephemeral-agent supervisor against Docker
make test-step-image  # run step images against Docker
make test-helm-e2e    # install and uninstall the chart in isolated Kind
make lint             # golangci-lint
make test             # Go tests and generated-file checks
make install-hooks    # use the Git hooks in .githooks
```

Each directory under `charts/buildkite-operator/examples` pairs a
`values.yaml` with its `rendered.yaml` and `NOTES.txt`, so chart changes show
up as diffs in review. The pre-commit hook stops a commit whose staged examples
are out of date, and CI fails on them too.

The end-to-end check deletes its Kind cluster when it finishes, which may clear
your current kubeconfig context.

The chart E2E test pins Kind 0.30's Kindnet image, because CI's kernel lacks
`CONFIG_NETFILTER_NETLINK_GLUE_CT`, which newer versions need for
NetworkPolicy. Remove the pin once CI's kernel supports it.

## Releasing the chart

Buildkite publishes tagged chart releases to the public Docker Hub repository
`buildkite/buildkite-operator-chart` at `registry-1.docker.io`, from the
Buildkite pipeline. Publishing waits for every check on the tagged commit to
pass, including the chart E2E test.

### One-time setup

- Enable **Build tags** in the pipeline's GitHub settings, and make sure branch
  filters and pipeline conditionals allow tag builds.
- Keep chart releases in the dedicated `buildkite/buildkite-operator-chart`
  repository, not a container-image repository with overlapping tags.
- Create a Buildkite Secret named `DOCKERHUB_TOKEN` in the agent cluster,
  holding a Docker Hub organization access token for `buildkite` with
  **Read & Write** access to `buildkite-operator-chart` and no delete access.
- Never put the token in pipeline YAML or repository files. The publisher
  uses the fixed username `buildkite`, so no username secret is needed.
- Restrict the secret to this pipeline and trusted builds with
  [agent access policies](https://buildkite.com/docs/pipelines/security/secrets/buildkite-secrets/access-policies).
- Those policies match pipelines and branches, not step keys or tags, and the
  release step's `if` condition isn't an access boundary.
- If untrusted pull request builds share this pipeline, isolate release access
  with a restricted agent queue or a separate release pipeline first.
- Protect `chart-v*` tags in GitHub so only trusted maintainers can create,
  change or delete them, because tagged code runs with publishing access.

### Publishing

Merge the chart changes and version bump, then tag that commit
`chart-v<version>` and push the tag. For example, tag `chart-v0.21.0` for
`version: 0.21.0` in `charts/buildkite-operator/Chart.yaml`. Only stable
`major.minor.patch` versions are supported, and `appVersion` isn't used.

The release script, `.buildkite/publish-chart.py`:

- Rejects mismatched versions and versions already published.
- Fails on registry authentication or network errors, rather than treating
  them as a missing version.
- Packages and pushes the chart, then pulls it back by digest and compares it
  with the original, recording the digest in the build log.
- Keeps Helm's login and packages in a temporary directory that it removes on
  exit.

Buildkite runs one publishing job at a time, so two builds can't both pass the
existing-version check. Docker Hub tags are mutable, so don't overwrite
releases with other tools.

If a job fails after pushing, the version may already be published, and a
retry won't overwrite it. Inspect the package and digest, and publish a new
version if it needs fixing. Don't delete a release just to make a retry pass.

To test release handling locally, run `python3 hack/test_publish_chart.py`. It
packages the chart with Helm against simulated registry and credential
services, without reading secrets or publishing.
