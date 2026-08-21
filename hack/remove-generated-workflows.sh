#!/usr/bin/env bash
# Remove GitHub Actions workflows that `kubebuilder edit --plugins=helm/v2-alpha
# --force` scaffolds but we do not use.
#
# The helm plugin writes `.github/workflows/test-chart.yml`, a chart lint/deploy
# CI job that duplicates our own pipelines. Delete it so `make helm` reproduces
# the committed tree, cleaning up now-empty parent directories.

set -euo pipefail

WORKFLOWS=(
	".github/workflows/test-chart.yml"
)

for f in "${WORKFLOWS[@]}"; do
	rm -f "$f"
done

rmdir .github/workflows 2>/dev/null || true
rmdir .github 2>/dev/null || true
