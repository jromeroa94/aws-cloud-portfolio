{{/*
Nombre base del chart (permite nameOverride). Truncado a 63 caracteres por el límite de las
etiquetas de Kubernetes.
*/}}
{{- define "platform-api.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Nombre completo de los recursos. Si el nombre de la release ya contiene el del chart
(release "platform-api" + chart "platform-api") se usa tal cual, de modo que el Deployment
y el Service se llaman exactamente "platform-api", como espera el pipeline.
*/}}
{{- define "platform-api.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Etiqueta helm.sh/chart (nombre y versión del chart).
*/}}
{{- define "platform-api.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Etiqueta de la imagen: image.tag o, si está vacío, appVersion del chart.
*/}}
{{- define "platform-api.imageTag" -}}
{{- .Values.image.tag | default .Chart.AppVersion }}
{{- end }}

{{/*
Referencia completa de la imagen.
*/}}
{{- define "platform-api.image" -}}
{{- printf "%s:%s" .Values.image.repository (include "platform-api.imageTag" .) }}
{{- end }}

{{/*
Etiquetas comunes (convención app.kubernetes.io/*).
*/}}
{{- define "platform-api.labels" -}}
helm.sh/chart: {{ include "platform-api.chart" . }}
{{ include "platform-api.selectorLabels" . }}
app.kubernetes.io/version: {{ include "platform-api.imageTag" . | quote }}
app.kubernetes.io/component: api
app.kubernetes.io/part-of: platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Etiquetas del selector. No cambian entre versiones: el selector de un Deployment es inmutable.
*/}}
{{- define "platform-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "platform-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Nombre de la KSA de la aplicación (fijado por Terraform como "platform-api").
*/}}
{{- define "platform-api.serviceAccountName" -}}
{{- .Values.serviceAccount.name | default (include "platform-api.fullname" .) }}
{{- end }}
