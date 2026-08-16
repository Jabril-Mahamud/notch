{{/*
Service name. Fails loudly rather than rendering a nameless Deployment when a
valueFile is missing or misnamed.
*/}}
{{- define "notch-app.name" -}}
{{- required "service.name is required - check services/<name>/service.yaml is reachable from the ApplicationSet" .Values.service.name -}}
{{- end -}}

{{- define "notch-app.env" -}}
{{- required "global.env is required - set it in envs/<env>/services.common.yaml" .Values.global.env -}}
{{- end -}}

{{- define "notch-app.secretName" -}}
{{- printf "%s-secrets" (include "notch-app.name" .) -}}
{{- end -}}

{{/*
Selector labels. Deliberately excludes app.kubernetes.io/instance: ArgoCD's
default instanceLabelKey is that same label, so ArgoCD would overwrite it and
break the selector.
*/}}
{{- define "notch-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "notch-app.name" . }}
{{- end -}}

{{- define "notch-app.labels" -}}
{{ include "notch-app.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
notch.io/env: {{ include "notch-app.env" . }}
{{- end -}}

{{/*
Every secret name any container mounts via envFrom, comma separated, for the
reloader annotation.
*/}}
{{- define "notch-app.reloadSecrets" -}}
{{- $default := include "notch-app.secretName" . -}}
{{- $all := list -}}
{{- range $cname, $c := .Values.service.deployment.containers -}}
{{- $all = concat $all (default (list $default) $c.secrets) -}}
{{- end -}}
{{- join "," (uniq $all) -}}
{{- end -}}
