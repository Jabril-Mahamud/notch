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

{{/* Tenant services set .Values.namespace; platform services get their own */}}
{{- define "notch.namespace" -}}
{{- .Values.namespace | default (include "notch.name" .) -}}
{{- end }}

{{/* Names that must be unique outside the namespace: Database and Role are
cluster-scoped, source secrets share notch-secrets. Tenant-prefixed so two
tenants can both run a "web" */}}
{{- define "notch.id" -}}
{{- if .Values.namespace }}{{ .Values.namespace }}-{{ end }}{{ include "notch.name" . }}
{{- end }}
