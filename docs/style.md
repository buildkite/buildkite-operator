# Documentation style

How to write and organize the chart's documentation.

## Where content goes

- `README.md` is for people installing and configuring the chart. Keep it to
  what they need to decide and do.
- `docs/appendices.md` holds supporting detail: one-time cluster setup,
  resources the chart creates, internals, and the reasoning behind security
  measures. Group it by purpose (Setup, Running jobs, Scaling, Images and
  registries), not by README order.
- `docs/maintainers.md` holds development commands and the release process.
- When a README section grows mechanism detail, opt-in caveats or setup
  steps, move them to an appendix and leave a one-line summary with a link.
- Link to upstream projects' docs (KEDA, OCI Accelerator, Kata, Sysbox)
  instead of repeating them. Pin links to the version the chart deploys, for
  example `blob/v0.5.0/docs/...`, and update them when the image changes.

## Writing style

- Address the reader as "you", in active voice, with American spelling.
- Don't use semicolons. Split the sentence, or join clauses with "and",
  "but" or "so".
- Wrap prose at 80 columns. Only links, tables and code may run longer.
- Keep paragraphs to two or three sentences. Prefer a lead-in sentence
  ending in a colon, followed by one-sentence bullets.
- Describe current behavior, not the change that introduced it. Avoid
  phrases like "the existing behavior", "no longer" or "by this change".
- Say what each setting does, not how the chart was built to do it.

## Formatting

- Settings tables have two columns, Setting and Description, with one row per
  setting. Start each description with its default in parentheses, such as
  "(default `60`)" or "(required)". Use a separate table per group of
  settings, such as `docker.*`.
- Put each command in a code block with a comment above it, rather than a
  table of commands or trailing comments.
- Lay out examples as the values first, then bullets.
- Use collapsible `<details>` blocks for secondary paths, such as installing
  from a checkout.
- Use GitHub alerts (`> [!WARNING]`) only for real hazards, such as
  privileged containers.
- Order headings, then tables, then descriptions.

## Terminology

- **runner pool:** an entry under `runnerPools`, serving one queue. Don't say
  "entry" or "queue" for the pool.
- **runner Pod:** the Kubernetes Pod. Use "agent" only for the Buildkite
  agent process inside it, which runs jobs, is busy or idle, and drains.
- **runtime:** the `runtime` setting (`standard`, `dind`, `kata`, `sysbox`).
  Don't call `dind` isolation.
- **OCI Accelerator:** the software, capitalized with no article. Use "the
  accelerator" for what a release deploys, and "accelerator replicas" for the
  plural. Keep "proxy" for Docker's proxy mechanism.
- **release:** a Helm release of this chart. Use `buildkite-runner-stack` as
  the example namespace.

## Accuracy

- Check claims against the templates, `values.yaml`, `values.schema.json`
  and upstream docs before writing them. Defaults in docs must match
  `values.yaml`.
- Don't overstate guarantees. Deletion cost and `safe-to-evict` are
  best-effort. Ephemeral agents aren't a security boundary. An admission
  policy limits a token rather than preventing escape. Say what a measure
  limits, and what it doesn't.
- Keep version examples in sync with `Chart.yaml`.

## Links and anchors

- Use relative links. Docs link back with `../README.md#anchor`.
- When renaming a heading, update every link to its anchor, including
  comments in `values.yaml` and templates.
- Run `make check-docs` to check that every relative link and heading anchor
  resolves.
