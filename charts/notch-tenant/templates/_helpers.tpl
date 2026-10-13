{{- define "tenant.name" -}}
{{- required "tenant.name is required" .Values.tenant.name -}}
{{- end }}

{{- define "tenant.labels" -}}
notch.dev/tenant: {{ include "tenant.name" . }}
app.kubernetes.io/managed-by: notch
{{- end }}
