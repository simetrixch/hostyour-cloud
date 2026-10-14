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
consumer-build.repoOwner — the organisation that owns the unit's repository, read off
unit.repoURL (https://github.com/<owner>/<repo>.git). It is the npm scope the unit's packages
are published under, and the prefix the platform's own builds are pushed under: the publish
pipeline publishes a package of this scope and no other (templates/pipeline-publish.yaml), so the
scope is a fact of the registration and never a value of this chart.
*/}}
{{- define "consumer-build.repoOwner" -}}
{{- $url := required "consumer-build: unit.repoURL is required (stamped by the fan-out ApplicationSet)" .Values.unit.repoURL -}}
{{- $owner := regexReplaceAll "^https://github\\.com/([^/]+)/[^/]+$" $url "${1}" -}}
{{- if eq $owner $url }}{{ fail (printf "consumer-build: unit.repoURL %q is not https://github.com/<owner>/<repository>[.git], and the build's npm scope is read off its owner" $url) }}{{ end -}}
{{- $owner -}}
{{- end -}}

{{- define "consumer-build.hasBuilds" -}}
{{- if gt (len (include "consumer-build.builds" . | fromJsonArray)) 0 -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/* The environment of the two commit status tasks of the ci Pipeline: the statuses token from
     build-git-https (key `token`, which posts commit statuses on the unit's own repository and writes
     nothing else), the repository as GitHub's API names it, the commit the gate proved and the run
     in the Tekton Dashboard. Takes a dict of repositoryPath and runURL. */}}
{{- define "consumer-build.ciCommitStatusEnv" -}}
- name: GITHUB_TOKEN
  valueFrom:
    secretKeyRef: { name: build-git-https, key: token }
- name: REPOSITORY_PATH
  value: {{ .repositoryPath | quote }}
- name: COMMIT
  value: "$(params.commit)"
- name: RUN_URL
  value: {{ .runURL | quote }}
{{- end }}

{{/* The user a repository's own code runs as wherever its test suites run: the check step of the
     ci and the build step of build-binaries, whose release/build.sh gates every part and the
     repository before it builds. It is pptruser, the user of the check image
     (ghcr.io/puppeteer/puppeteer, UID 10042 in its Dockerfile), and never root: root keeps
     CAP_DAC_OVERRIDE and reads and writes through any mode, so a test that expects a directory to
     refuse a write (a record this account cannot remove) is red in a pod and green on a
     workstation. */}}
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
