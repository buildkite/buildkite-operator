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

{{- define "buildkite-operator.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "buildkite-operator.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- required "serviceAccount.name is required when serviceAccount.create is false" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "buildkite-operator.runnerPoolName" -}}
{{- default (printf "%s-runner-pool" (include "buildkite-operator.fullname" .) | trunc 63 | trimSuffix "-") .Values.runnerPool.name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "buildkite-operator.agentTokenSecretName" -}}
{{- printf "%s-agent-token" (include "buildkite-operator.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
