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

{{- define "buildkite-operator.runnerName" -}}
{{- default (printf "%s-runners" (include "buildkite-operator.fullname" .) | trunc 63 | trimSuffix "-") .Values.runners.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "buildkite-operator.agentTokenSecretName" -}}
{{- printf "%s-agent-token" (include "buildkite-operator.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "buildkite-operator.metricsTokenSecretName" -}}
{{- if .Values.metricsToken.existingSecret.name }}
{{- .Values.metricsToken.existingSecret.name }}
{{- else }}
{{- include "buildkite-operator.agentTokenSecretName" . }}
{{- end }}
{{- end }}
