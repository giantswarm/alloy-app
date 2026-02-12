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
