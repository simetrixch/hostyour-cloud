{{/*
Shared helpers for all library charts in charts/. Each define is evaluated
with the CALLER's context (the consuming chart passes its own `.`), so
.Chart.Name / .Values.nameOverride resolve per consuming chart — output is
identical to the per-chart helpers these replaced.

NOTE on selectorLabels: Deployment spec.selector is IMMUTABLE. Changing the
content of common.selectorLabels recreates every consumer's Deployment.
Never edit it without a migration plan.
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "common.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "common.fullname" -}}
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
Create chart name and version as used by the chart label.
*/}}
{{- define "common.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "common.labels" -}}
helm.sh/chart: {{ include "common.chart" . }}
{{ include "common.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "common.selectorLabels" -}}
app.kubernetes.io/name: {{ include "common.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Registry host for THIS cluster's images — the ONE shared cross-cluster surface.
Returns `global.endpoints.registry.host` when set (a plain host stamped on the
install branch: zot.<build-plane> from the cluster map, e.g.
zot.m1.example.com), else the self-hosted default composed from
env+domain (zot.<domain>). One tpl pass — safe to reference from any
template OR to `tpl` from a value.
*/}}
{{- define "common.registryHost" -}}
{{- .Values.global.endpoints.registry.host | default (printf "zot.%s" .Values.global.domain) -}}
{{- end }}

{{/*
common.buildImage — the full image ref of ONE builds[] pin, the pin grammar
every values-<stage>.yaml carries: builds[]{name,image,tag}. `image` is the
FLAT build name (== the zot repo — no prefix of any kind left to compose,
not the tier and not the unit), so the ref is <registryHost>/<image>:<tag>. The release
bump finds pins by exactly this grammar; an image composed any other way
would be invisible to it.
Call: include "common.buildImage" (dict "root" $ "builds" .Values.builds "name" "manager")
(`builds` is passed from the CALLER so the reading template names
.Values.builds itself.) Fails the render when the named pin is absent — a
missing pin must never render an empty image ref.
*/}}
{{- define "common.buildImage" -}}
{{- printf "%s/%s:%s" (include "common.registryHost" .root) (include "common.buildImageName" .) (include "common.buildTag" .) -}}
{{- end }}

{{/*
common.buildImageName / common.buildTag — the two halves of the same pin, for
templates that need one of them alone (e.g. a version env). Same call shape
as common.buildImage.
*/}}
{{- define "common.buildImageName" -}}
{{- $found := dict -}}
{{- range .builds }}{{- if eq .name $.name }}{{- $found = . -}}{{- end }}{{- end -}}
{{- $found.image | required (printf "builds[] carries no entry named %q with an image — the values-<stage>.yaml pin is missing" .name) -}}
{{- end }}

{{- define "common.buildTag" -}}
{{- $found := dict -}}
{{- range .builds }}{{- if eq .name $.name }}{{- $found = . -}}{{- end }}{{- end -}}
{{- $found.tag | required (printf "builds[] carries no entry named %q with a tag — the values-<stage>.yaml pin is missing" .name) -}}
{{- end }}

