{{/*
consumer-build.unitName — the unit this render belongs to, from the stamped
registration values (UNIT mode). `required` guards a render where the fan-out
forgot the valuesObject: every unit-mode template keys on this name, so an
empty one must fail the render, not produce anonymous objects.
*/}}
{{- define "consumer-build.unitName" -}}
{{- required "consumer-build: unit.name is required (stamped by the fan-out ApplicationSet)" .Values.unit.name -}}
{{- end -}}

{{/*
consumer-build.builds — the ATTESTED builds[] of the unit, decoded from the
JSON string the fan-out stamps (unit.buildsJson). These are the build NAMES
from registrations/<unit>/build.yaml — each name IS the zot repo the release
pushes to, under the owner's prefix for the platform's own builds alone
(templates/pipeline-release.yaml, the push path).
*/}}
{{- define "consumer-build.builds" -}}
{{- required "consumer-build: unit.buildsJson is required (stamped by the fan-out ApplicationSet)" .Values.unit.buildsJson | fromJsonArray | toJson -}}
{{- end -}}

{{/*
consumer-build.forgejoHost — the host of the Forgejo this installation's repositories stand on:
global.repositoryCredentials.forgejo.host where .enabled is true, the answer the branch program writes
into installation/values/repository-credentials.yaml, and nothing where the installation has none.
*/}}
{{- define "consumer-build.forgejoHost" -}}
{{- $forgejo := dig "repositoryCredentials" "forgejo" dict .Values.global -}}
{{- if $forgejo.enabled -}}
{{- required "consumer-build: global.repositoryCredentials.forgejo.host is required when the Forgejo is enabled (installation/values/repository-credentials.yaml)" $forgejo.host -}}
{{- end -}}
{{- end -}}

{{/*
consumer-build.repoHost — the host of the unit's repository, unit.repoURL being
https://<host>/<owner>/<repo>[.git]: github.com, or the Forgejo of the installation. Any other host
fails the render by name.
*/}}
{{- define "consumer-build.repoHost" -}}
{{- $url := required "consumer-build: unit.repoURL is required (stamped by the fan-out ApplicationSet)" .Values.unit.repoURL -}}
{{- $hosts := list "github.com" -}}
{{- with include "consumer-build.forgejoHost" . }}{{ $hosts = append $hosts . }}{{ end -}}
{{- $host := regexReplaceAll "^https://([^/]+)/[^/]+/[^/]+$" $url "${1}" -}}
{{- if or (eq $host $url) (not (has $host $hosts)) }}{{ fail (printf "consumer-build: unit.repoURL %q is not https://<host>/<owner>/<repository>[.git] on %s, and the build's npm scope is read off its owner" $url (join " or " $hosts)) }}{{ end -}}
{{- $host -}}
{{- end -}}

{{/*
consumer-build.repoOwner — the organisation that owns the unit's repository, read off
unit.repoURL (https://<host>/<owner>/<repo>.git, see consumer-build.repoHost). It is the npm scope the
unit's packages are published under, and the prefix the platform's own builds are pushed under: the
publish pipeline publishes a package of this scope and no other (templates/pipeline-publish.yaml), so
the scope is a fact of the registration and never a value of this chart.
*/}}
{{- define "consumer-build.repoOwner" -}}
{{- $null := include "consumer-build.repoHost" . -}}
{{- regexReplaceAll "^https://[^/]+/([^/]+)/[^/]+$" .Values.unit.repoURL "${1}" -}}
{{- end -}}

{{- define "consumer-build.hasBuilds" -}}
{{- if gt (len (include "consumer-build.builds" . | fromJsonArray)) 0 -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/* The user a repository's own code runs as on the build plane: the build step of build-binaries,
     whose release/build.sh gates every part and the repository before it builds. It is pptruser, the user of the check image
     (ghcr.io/puppeteer/puppeteer, UID 10042 in its Dockerfile), and never root: root keeps
     CAP_DAC_OVERRIDE and reads and writes through any mode, so a test that expects a directory to
     refuse a write (a record this account cannot remove) is red in a pod and green on a
     workstation. */}}
{{/* The image a repository's check, pack and build run in: ghcr.io/puppeteer/puppeteer, with Node 24,
     git, bash, curl and the Chrome for Testing that PDF tests need, on the node:24-bookworm base. It
     is pulled from the owner's mirror of ghcr.io, at the digest of 25.13.0 for linux/amd64, a Docker
     v2 schema 2 manifest the mirror keeps as it is. */}}
{{- define "consumer-build.nodeImage" -}}
{{ include "common.buildRegistry" . }}/ghcr.io/puppeteer/puppeteer:25.13.0@sha256:893118e0546f8cee371a0ae09c8489d1e9c40de28c45df9d811d4233203b81a3
{{- end -}}

{{/* "true" for the platform tree on the owner's master, whose registry/owner is global.buildRegistry, and
     nothing for any other unit or cluster. Its publish run fills the mirror the platform's images are
     pulled from. */}}
{{- define "consumer-build.isPlatformMirror" -}}
{{- if and .Values.unit (eq (.Values.unit.repoURL | default "") (required "consumer-build: global.platformUrl is required (platform values chain)" .Values.global.platformUrl)) (eq (printf "%s/%s" (include "common.registryHost" .) (include "consumer-build.repoOwner" . | lower)) (include "common.buildRegistry" .)) -}}
true
{{- end -}}
{{- end -}}

{{/* "true" for global.buildRegistryUnit on the owner's master, whose registry/owner is global.buildRegistry:
     the unit that builds the platform's own images, which its release run pushes under that owner and pins
     in clusters/inventories/<app>/values-<stage>.yaml. */}}
{{- define "consumer-build.isPlatformBuilds" -}}
{{- if and .Values.unit (eq (include "consumer-build.unitName" .) (required "consumer-build: global.buildRegistryUnit is required (platform values chain)" .Values.global.buildRegistryUnit)) (eq (printf "%s/%s" (include "common.registryHost" .) (include "consumer-build.repoOwner" .)) (include "common.buildRegistry" .)) -}}
true
{{- end -}}
{{- end -}}

{{/* "true" for the engine's repository on the owner's master, whose registry/owner is global.buildRegistry:
     lifecycle/driver.sh fetches the engine from <owner>/ansiwise-cli there (RELEASES). Its publish run puts
     each release under its digest and then under its tag, and release/release.sh of ansiwise-cli waits for
     that tag before it pins the engine. */}}
{{- define "consumer-build.isPlatformEngine" -}}
{{- if and .Values.unit (eq (.Values.unit.repoURL | default "") (printf "%s/ansiwise-cli.git" (regexReplaceAll "/[^/]+$" (required "consumer-build: global.platformUrl is required (platform values chain)" .Values.global.platformUrl) ""))) (eq (printf "%s/%s" (include "common.registryHost" .) (include "consumer-build.repoOwner" . | lower)) (include "common.buildRegistry" .)) -}}
true
{{- end -}}
{{- end -}}

{{/* The images of the publish run, each pinned by its digest: bash, jq, tar and sha256sum; and skopeo for
     the copies, at its -immutable tag, because the plain tag is rebuilt every night. */}}
{{- define "consumer-build.toolsImage" -}}
alpine/k8s:1.35.6@sha256:b7a12c5ddf261994c33d2eaaa06fd69a0803ff6b38683bfa3d30a76dcdf92807
{{- end -}}
{{- define "consumer-build.skopeoImage" -}}
quay.io/skopeo/stable:v1.22.3-immutable@sha256:c0ee1f4edca5c01cb8d5611124f92f3cc47196ecab68aee5d0f90834e00574d5
{{- end -}}

{{- define "consumer-build.checkUser" -}}
10042
{{- end -}}

{{- define "consumer-build.checkUserContext" -}}
runAsUser: {{ include "consumer-build.checkUser" . }}
runAsNonRoot: true
allowPrivilegeEscalation: false
{{- end -}}

{{/* The step that hands the folders pods of root made to that user, before a step of it writes
     into them (node_modules, build output, the test databases, the binaries). It runs as the root
     of its image. Takes a dict of image and folders. */}}
{{- define "consumer-build.handOverStep" -}}
- name: hand-over
  image: {{ .image }}
  script: |
    #!/usr/bin/env sh
    set -eu
    chown -R -h {{ include "consumer-build.checkUser" . }} {{ .folders }}
  computeResources:
    requests: { cpu: 50m, memory: 32Mi }
    limits: { cpu: 500m, memory: 64Mi }
{{- end -}}
