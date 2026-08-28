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
common.buildRegistry — the registry namespace THIS PLATFORM's own images are
published under, from global.buildRegistry (clusters/platform/values-common.yaml,
which states why it stands on the trunk). Required rather than defaulted: a
values chain missing it would otherwise compose a ref against an empty host and
the pod would report only ImagePullBackOff, naming nothing.
*/}}
{{- define "common.buildRegistry" -}}
{{- .Values.global.buildRegistry | required "global.buildRegistry is not in this chart's values chain — clusters/platform/values-common.yaml states it, and every ApplicationSet loads that file first" -}}
{{- end }}

{{/*
common.buildImage — the full image ref of ONE builds[] pin, the pin grammar
every values-<stage>.yaml carries: builds[]{name,image,tag}. `image` is the
FLAT build name (no prefix of any kind left to compose, not the tier and not
the unit), so the ref is <buildRegistry>/<image>:<tag>. The release bump finds
pins by exactly this grammar; an image composed any other way would be
invisible to it.

IT IS buildRegistry AND NOT registryHost. Every pin in this grammar names an
image of an open-source repository this platform is built from, published to
ghcr.io by the seed-images workflow on the release tag, and the pods pull it
from there. `common.registryHost` — the cluster's own zot — carries what is
built INSIDE a cluster instead: the consumer and tenant images of the release
pipeline, which are customer code. The two are separate on purpose, and a pin
composed against the wrong one reaches a registry that was never asked to hold
it.
Call: include "common.buildImage" (dict "root" $ "builds" .Values.builds "name" "manager")
(`builds` is passed from the CALLER so the reading template names
.Values.builds itself.) Fails the render when the named pin is absent — a
missing pin must never render an empty image ref.
*/}}
{{- define "common.buildImage" -}}
{{- printf "%s/%s:%s" (include "common.buildRegistry" .root) (include "common.buildImageName" .) (include "common.buildTag" .) -}}
{{- end }}

{{/*
common.buildImageName / common.buildTag — the two halves of the same pin, for
templates that need one of them alone (e.g. a version env). Same call shape
as common.buildImage, `root` included: common.buildTag reads
global.placeholderTag through it.
A stage no release has reached carries that value as its tag
(clusters/platform/values-common.yaml states it, and the release bump writes the minted
image tag over it). common.buildTag STOPS THE RENDER while it stands there:
the pin says which image the stage runs, and before the first release there is
no such image — a rendered ref would put the app in ImagePullBackOff instead of
naming what is missing.
*/}}
{{- define "common.buildImageName" -}}
{{- $found := dict -}}
{{- range .builds }}{{- if eq .name $.name }}{{- $found = . -}}{{- end }}{{- end -}}
{{- $found.image | required (printf "builds[] carries no entry named %q with an image — the values-<stage>.yaml pin is missing" .name) -}}
{{- end }}

{{- define "common.buildTag" -}}
{{- $found := dict -}}
{{- range .builds }}{{- if eq .name $.name }}{{- $found = . -}}{{- end }}{{- end -}}
{{- $tag := $found.tag | required (printf "builds[] carries no entry named %q with a tag — the values-<stage>.yaml pin is missing" .name) -}}
{{- $placeholder := .root.Values.global.placeholderTag | required "global.placeholderTag is not in this chart's values chain — clusters/platform/values-common.yaml states it, and every ApplicationSet loads that file first" -}}
{{- if eq $tag $placeholder }}{{- fail (printf "builds[] entry %q is pinned at %q, the tag a stage carries before its first release: no release has written this stage's pin, so there is no image to run. The bump task of the <unit>-release Pipeline writes the minted image tag over it (clusters/inventories/consumer-build/templates/pipeline-release.yaml)." .name $placeholder) }}{{- end -}}
{{- $tag -}}
{{- end }}

