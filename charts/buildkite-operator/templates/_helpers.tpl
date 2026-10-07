{{- define "buildkite-operator.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "buildkite-operator.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "buildkite-operator.labels" -}}
app.kubernetes.io/name: {{ include "buildkite-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
{{- end }}

{{/*
Validates every queue entry and returns them as a JSON list of
{name, resourceName, settings}, sorted by name. settings is the entry merged
over .Values.defaults, with the entry taking precedence.
*/}}
{{- define "buildkite-operator.queueEntries" -}}
{{- $root := . }}
{{- $entries := list }}
{{- $byQueue := dict }}
{{- range $name := keys (.Values.queues | default dict) | sortAlpha }}
{{- $entry := get $root.Values.queues $name }}
{{- if kindIs "invalid" $entry }}
{{- continue }}
{{- end }}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name) }}
{{- fail (printf "queues.%s: names must be lowercase letters, digits and hyphens, starting and ending with a letter or digit" $name) }}
{{- end }}
{{- $settings := mergeOverwrite (deepCopy ($root.Values.defaults | default dict)) (deepCopy $entry) }}
{{- $resourceName := printf "%s-%s" $root.Release.Name $name }}
{{- if gt (len $resourceName) 50 }}
{{- fail (printf "queues.%s: release and queue names combined (%s) must be at most 50 characters" $name $resourceName) }}
{{- end }}
{{- $queue := $settings.queue | default "" }}
{{- if not $queue }}
{{- fail (printf "queues.%s.queue is required" $name) }}
{{- end }}
{{- if hasKey $byQueue $queue }}
{{- fail (printf "queues.%s and queues.%s both use Buildkite queue %q; each queue may appear only once" (get $byQueue $queue) $name $queue) }}
{{- end }}
{{- $_ := set $byQueue $queue $name }}
{{- $maxReplicas := int ($settings.maxReplicas | default 0) }}
{{- if lt $maxReplicas 1 }}
{{- fail (printf "queues.%s.maxReplicas must be at least 1" $name) }}
{{- end }}
{{- if gt (int $settings.minReplicas) $maxReplicas }}
{{- fail (printf "queues.%s.minReplicas must be less than or equal to maxReplicas" $name) }}
{{- end }}
{{- $entries = append $entries (dict "name" $name "resourceName" $resourceName "settings" $settings) }}
{{- end }}
{{- toJson $entries }}
{{- end }}

{{- define "buildkite-operator.agentTokenSecretName" -}}
{{- printf "%s-agent-token" (include "buildkite-operator.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "buildkite-operator.triggerAuthenticationName" -}}
{{- printf "%s-metrics" (include "buildkite-operator.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "buildkite-operator.deletionCostName" -}}
{{- printf "%s-deletion-cost" (include "buildkite-operator.fullname" . | trunc 49 | trimSuffix "-") }}
{{- end }}

{{- define "buildkite-operator.ephemeralAgentName" -}}
{{- printf "%s-ephemeral-agent" (include "buildkite-operator.fullname" . | trunc 47 | trimSuffix "-") }}
{{- end }}

{{- define "buildkite-operator.ociAcceleratorName" -}}
{{- printf "%s-oci-accelerator" (include "buildkite-operator.fullname" . | trunc 36 | trimSuffix "-") }}
{{- end }}

{{/*
Returns "true" when a queue entry's Docker daemon pulls through the OCI
accelerator. Called with (dict "root" $ "settings" <entry settings>).
*/}}
{{- define "buildkite-operator.usesOciAccelerator" -}}
{{- if and .root.Values.ociAccelerator.enabled (has .settings.runtime (list "dind" "kata" "sysbox")) .settings.docker.ociAccelerator -}}
true
{{- end }}
{{- end }}

{{/*
Returns "true" when any queue entry pulls through the OCI accelerator, so the
release installs it.
*/}}
{{- define "buildkite-operator.ociAcceleratorUsed" -}}
{{- $root := . }}
{{- range $entry := include "buildkite-operator.queueEntries" . | fromJsonArray }}
{{- if include "buildkite-operator.usesOciAccelerator" (dict "root" $root "settings" $entry.settings) }}
{{- print "true" }}
{{- break }}
{{- end }}
{{- end }}
{{- end }}

{{- define "buildkite-operator.ociAcceleratorCASecretName" -}}
{{- .Values.ociAccelerator.ca.existingSecret.name | default (printf "%s-ca" (include "buildkite-operator.ociAcceleratorName" .)) }}
{{- end }}

{{- define "buildkite-operator.ociAcceleratorCAHookName" -}}
{{- printf "%s-ca-hook" (include "buildkite-operator.ociAcceleratorName" .) }}
{{- end }}

{{- define "buildkite-operator.ociAcceleratorProxyURL" -}}
{{- printf "http://%s.%s.svc:3128" (include "buildkite-operator.ociAcceleratorName" .) .Release.Namespace }}
{{- end }}

{{- define "buildkite-operator.agentTokenSecretRef" -}}
{{- if .Values.agentToken.existingSecret.name -}}
name: {{ .Values.agentToken.existingSecret.name | quote }}
key: {{ .Values.agentToken.existingSecret.key | quote }}
{{- else -}}
name: {{ include "buildkite-operator.agentTokenSecretName" . }}
key: token
{{- end }}
{{- end }}

{{- define "buildkite-operator.metricsTokenSecretName" -}}
{{- if .Values.metricsToken.existingSecret.name }}
{{- .Values.metricsToken.existingSecret.name }}
{{- else }}
{{- include "buildkite-operator.agentTokenSecretName" . }}
{{- end }}
{{- end }}
