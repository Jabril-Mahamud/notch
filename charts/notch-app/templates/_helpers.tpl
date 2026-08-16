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
Every secret any container reads, comma separated, for the reloader annotation.
Covers both routes into a container: whole secrets via envFrom (`secrets`) and
individual keys via secretKeyRef (`envSecrets`). Missing the second one means a
rotated database password never restarts the pod that uses it.
*/}}
{{- define "notch-app.reloadSecrets" -}}
{{- $default := include "notch-app.secretName" . -}}
{{- $all := list -}}
{{- range $cname, $c := .Values.service.deployment.containers -}}
{{- $all = concat $all (default (list $default) $c.secrets) -}}
{{- range $k, $ref := (default (dict) $c.envSecrets) -}}
{{- $all = append $all $ref.name -}}
{{- end -}}
{{- end -}}
{{- join "," (uniq $all) -}}
{{- end -}}
