{{- define "notch.name" -}}
{{- required "service.name is required" .Values.service.name -}}
{{- end }}

{{/* No app.kubernetes.io/instance: ArgoCD overwrites it and selectors are immutable */}}
{{- define "notch.selector" -}}
app.kubernetes.io/name: {{ include "notch.name" . }}
{{- end }}

{{- define "notch.labels" -}}
{{ include "notch.selector" . }}
app.kubernetes.io/managed-by: notch
{{- end }}
