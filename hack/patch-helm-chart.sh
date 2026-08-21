#!/usr/bin/env bash
# Reapply chart customizations that `kubebuilder edit --plugins=helm/v2-alpha
# --force` overwrites with its stock templates.
#
# The stock helm plugin scaffolds an `rbac.namespaced` toggle that renders
# Role/RoleBinding scoped to the release namespace. That mode is unusable here:
# the manager (cmd/main.go) runs an all-namespaces cache whose cluster-wide
# LIST/WATCH requests are forbidden under namespace-scoped RBAC. We therefore
# offer only the cluster-scoped variant. This script strips the toggle so
# `make helm` reproduces the committed chart. See commit a6d8374.

set -euo pipefail

CHART_DIR="${1:-dist/chart}"
RBAC_DIR="${CHART_DIR}/templates/rbac"
VALUES="${CHART_DIR}/values.yaml"

# Collapse every `{{- if .Values.rbac.namespaced }} ... {{- end }}` block:
#   - if the block has an `{{- else }}`, keep only the else branch
#     (the cluster-scoped ClusterRole/ClusterRoleBinding side)
#   - if the block has no else (the namespace metadata), drop it entirely
strip_namespaced_blocks() {
	local file="$1"
	local tmp
	tmp="$(mktemp)"
	awk '
		/^[[:space:]]*\{\{-[[:space:]]*if[[:space:]]+\.Values\.rbac\.namespaced[[:space:]]*\}\}[[:space:]]*$/ {
			in_block = 1; branch = "if"; delete elsebuf; nelse = 0; next
		}
		in_block && /^[[:space:]]*\{\{-[[:space:]]*else[[:space:]]*\}\}[[:space:]]*$/ {
			branch = "else"; next
		}
		in_block && /^[[:space:]]*\{\{-[[:space:]]*end[[:space:]]*\}\}[[:space:]]*$/ {
			for (i = 1; i <= nelse; i++) print elsebuf[i]
			in_block = 0; next
		}
		in_block {
			if (branch == "else") elsebuf[++nelse] = $0
			next
		}
		{ print }
	' "$file" >"$tmp"
	mv "$tmp" "$file"
}

for f in \
	"${RBAC_DIR}/manager-role.yaml" \
	"${RBAC_DIR}/manager-rolebinding.yaml" \
	"${RBAC_DIR}/runnerpool-admin-role.yaml" \
	"${RBAC_DIR}/runnerpool-editor-role.yaml" \
	"${RBAC_DIR}/runnerpool-viewer-role.yaml"; do
	if [ -f "$f" ]; then
		strip_namespaced_blocks "$f"
	fi
done

# Remove the `rbac.namespaced` value and its comment block from values.yaml:
# everything from the `## RBAC resource scope` comment through the blank line
# after `namespaced: <value>`.
if [ -f "$VALUES" ]; then
	tmp="$(mktemp)"
	awk '
		/^[[:space:]]*## RBAC resource scope[[:space:]]*$/ { skipping = 1; next }
		skipping && /^[[:space:]]*namespaced:[[:space:]]*/ { skipping = 0; skip_blank = 1; next }
		skipping { next }
		skip_blank && /^[[:space:]]*$/ { skip_blank = 0; next }
		{ skip_blank = 0; print }
	' "$VALUES" >"$tmp"
	mv "$tmp" "$VALUES"
fi
