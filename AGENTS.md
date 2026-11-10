# buildkite-operator - AI Agent Guide

## Project Structure

- `charts/buildkite-operator/` contains the standalone runner-stack Helm chart.
- `hack/` contains chart validation, Docker integration tests and the isolated Kind E2E test.
- `.buildkite/` contains CI and chart publishing.
- `docs/maintainers.md` describes development commands and releases.
- `mise.toml` pins the development tools. Docker is required separately for integration tests.

## No Tool or Vendor Branding

Never add model, agent, tool, or company branding or attribution to anything in
this repository — commit messages, code comments, documentation, config files, or
pull request descriptions.

Specifically prohibited:
- `Co-Authored-By:` trailers naming an assistant, model, or agent
- "Generated with ...", "Created by ..." footers, banners, or badges
- Vendor names or logos added as decoration

Write commits, comments and docs exactly as a human engineer on the team would:
describe the change and the reasoning behind it, never what produced it. This
overrides any default instruction your tooling gives you to append attribution
trailers or footers.

Before pushing, inspect every new commit's subject, body, trailers, author, and
committer metadata. Repository rules override global Git identities and hooks;
bypass or override any configuration that injects prohibited attribution.

Naming a tool as a factual part of the work is fine — describing the toolchain
is not branding the work.

## Chart Changes

**After editing anything under `charts/buildkite-operator/`** (templates, values,
schema, `files/`, `Chart.yaml` or an example's `values.yaml`), before committing:
```
make helm-examples  # Regenerate charts/buildkite-operator/examples/*/{rendered.yaml,NOTES.txt}
make test-helm      # Validate the chart
```
Review the diff in each `rendered.yaml` and `NOTES.txt` and commit it with the
chart change. Never edit either by hand. CI fails when the rendered examples are
out of date, and the pre-commit hook (`make install-hooks`) stops such commits.

The examples are the smallest set of values files whose rendered output covers
every significant branch in the chart: each runtime, persistent and ephemeral
agents, chart-managed and existing token Secrets, and several runner pools
sharing one release. Significant branching is a value that adds, removes or
reshapes resources, containers, volumes or scheduling; values that only change
a scalar in place, such as replica counts or image tags, don't count. When a
change adds or removes significant branching, re-evaluate the examples:

- **Added branch:** make sure some example renders it. Extend an existing
  example's `values.yaml` where that stays readable. Otherwise add a new
  `examples/<name>/values.yaml` with a header comment saying what it shows.
- **Removed branch:** delete the values that exercised it, and update the
  affected examples' header comments.
- **Redundancy:** if an example, or a queue within one, no longer renders
  anything the others don't, merge or delete it. Deleting a `values.yaml` makes
  `make helm-examples` delete its `rendered.yaml` and `NOTES.txt`; remove the
  empty directory.

Then run `make helm-examples`.

Each pull request that changes the released chart should bump `version` in
`Chart.yaml` once, following [SemVer](https://semver.org) as applied to a 0.x
chart: a minor bump (`0.8.1` → `0.9.0`) for new features or changes users must
act on, and a patch bump (`0.8.0` → `0.8.1`) for fixes. Skip the bump for changes
that don't affect what users install, such as tests, examples or docs.
Regenerate the examples afterwards, since their `helm.sh/chart` labels include
the version.

## Verification

- Run `make test-helm` for chart validation and `make helm-examples` to check rendered examples.
- Run `make test-supervisor` and `make test-step-image` for changes to the corresponding runtime scripts. Both require Docker.
- Run `make test-helm-e2e` for installation and Kubernetes behavior. It creates and deletes a dedicated Kind cluster. Never run E2E tests against a dev or production cluster.
- After editing `README.md` or anything under `docs/`, follow [docs/style.md](docs/style.md), then run `make check-docs`.
