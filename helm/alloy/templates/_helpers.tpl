{{/*
Common labels
*/}}
{{- define "alloy.labels" -}}
helm.sh/chart: {{ include "alloy.chart" . }}
{{ include "alloy.selectorLabels" . }}
{{- if index .Values "$chart_tests" }}
app.kubernetes.io/version: "vX.Y.Z"
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- else }}
{{/* substr trims delimeter prefix char from alloy.imageId output
    e.g. ':' for tags and '@' for digests.
    For digests, we crop the string to a 7-char (short) sha. */}}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: alloy
application.giantswarm.io/team: {{ index .Chart.Annotations "io.giantswarm.application.team" | default "atlas" | quote }}
giantswarm.io/managed-by: {{ .Release.Name | quote }}
giantswarm.io/service-type: managed
{{- end }}
{{- end }}

{{/*
For serviceWhenDisabled: the subchart's helpers are dropped along with the subchart, and
these must stay identical to them or the two Services diverge.
*/}}
{{- define "alloy-app.name" -}}
{{- default .Chart.Name (.Values.alloy | default dict).nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "alloy-app.fullname" -}}
{{- $override := (.Values.alloy | default dict).fullnameOverride }}
{{- if $override }}
{{- $override | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := include "alloy-app.name" . }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "alloy-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "alloy-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "alloy-app.disabledLabels" -}}
{{ include "alloy-app.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: alloy
application.giantswarm.io/team: {{ index .Chart.Annotations "io.giantswarm.application.team" | default "atlas" | quote }}
giantswarm.io/managed-by: {{ .Release.Name | quote }}
giantswarm.io/service-type: managed
{{- end }}
