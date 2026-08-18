{{/*
Whether the vCenter receiver applies to this provider.
Outputs "true" for vSphere and Cloud Director, and an empty string for all other
providers. Do not output "false": a non-empty string is always truthy in a template.
Use with: {{- if include "vcenter-receiver.enabled" . }}
*/}}
{{- define "vcenter-receiver.enabled" -}}
{{- if has (.Values.provider | default "") (list "vsphere" "cloud-director") -}}
true
{{- end -}}
{{- end }}

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
