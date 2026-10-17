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
{{/* The image a repository's check, pack and build run in: ghcr.io/puppeteer/puppeteer, with Node 24,
     git, bash, curl and the Chrome for Testing that PDF tests need, on the node:24-bookworm base. It
     is pulled from the owner's mirror of ghcr.io, at the digest of 25.13.0 for linux/amd64, a Docker
     v2 schema 2 manifest the mirror keeps as it is. */}}
{{- define "consumer-build.nodeImage" -}}
{{ include "common.buildRegistry" . }}/ghcr.io/puppeteer/puppeteer:25.13.0@sha256:893118e0546f8cee371a0ae09c8489d1e9c40de28c45df9d811d4233203b81a3
{{- end -}}

{{/* "true" for the platform tree on the owner's master, whose registry/owner is global.buildRegistry, and
     nothing for any other unit or cluster. Its publish run fills the mirror the platform's images are
     pulled from and writes the recovery folder of the owner's master at every platform tag. */}}
{{- define "consumer-build.isPlatformMirror" -}}
{{- if and .Values.unit (eq (.Values.unit.repoURL | default "") "https://github.com/simetrixch/hostyour-cloud.git") (eq (printf "%s/%s" (include "common.registryHost" .) (include "consumer-build.repoOwner" . | lower)) (include "common.buildRegistry" .)) -}}
true
{{- end -}}
{{- end -}}

{{/* "true" for global.buildRegistryUnit on the owner's master, whose registry/owner is global.buildRegistry:
     the unit that builds the platform's own images, which its release run pushes under that owner and pins
     in clusters/inventories/<app>/values-<stage>.yaml. That run writes their archives into the recovery folder
     of the owner's master before its bump pins them. */}}
{{- define "consumer-build.isPlatformBuilds" -}}
{{- if and .Values.unit (eq (include "consumer-build.unitName" .) (required "consumer-build: global.buildRegistryUnit is required (platform values chain)" .Values.global.buildRegistryUnit)) (eq (printf "%s/%s" (include "common.registryHost" .) (include "consumer-build.repoOwner" .)) (include "common.buildRegistry" .)) -}}
true
{{- end -}}
{{- end -}}

{{/* "true" for the engine's repository on the owner's master, whose registry/owner is global.buildRegistry:
     lifecycle/driver.sh fetches the engine from <owner>/ansiwise-cli there (RELEASES). Its publish run writes
     each release into the recovery folder of the owner's master before it tags the release, and
     release/release.sh of ansiwise-cli waits for that tag before it pins the engine. */}}
{{- define "consumer-build.isPlatformEngine" -}}
{{- if and .Values.unit (eq (.Values.unit.repoURL | default "") "https://github.com/simetrixch/ansiwise-cli.git") (eq (printf "%s/%s" (include "common.registryHost" .) (include "consumer-build.repoOwner" . | lower)) (include "common.buildRegistry" .)) -}}
true
{{- end -}}
{{- end -}}

{{/* "true" where a run writes the recovery folder of the owner's master: the platform tree, the platform's own
     builds and the engine, each on the owner's master. The recovery credential and the pinhole to the storage
     box render there alone. */}}
{{- define "consumer-build.writesRecoveryFolder" -}}
{{- if or (include "consumer-build.isPlatformMirror" .) (include "consumer-build.isPlatformBuilds" .) (include "consumer-build.isPlatformEngine" .) -}}
true
{{- end -}}
{{- end -}}

{{/* The images of the publish run and of recovery-export, each pinned by its digest: bash, jq, tar and
     sha256sum; skopeo for the copies, at its -immutable tag, because the plain tag is rebuilt every night;
     and rclone for the storage box, at the digest of 1.75.2 on Docker Hub. */}}
{{- define "consumer-build.toolsImage" -}}
alpine/k8s:1.35.6@sha256:b7a12c5ddf261994c33d2eaaa06fd69a0803ff6b38683bfa3d30a76dcdf92807
{{- end -}}
{{- define "consumer-build.skopeoImage" -}}
quay.io/skopeo/stable:v1.22.3-immutable@sha256:c0ee1f4edca5c01cb8d5611124f92f3cc47196ecab68aee5d0f90834e00574d5
{{- end -}}
{{- define "consumer-build.rcloneImage" -}}
rclone/rclone:1.75.2@sha256:2687085f718d3c628f7fdfb77c52a1d344332aed543110bb88088f2c70d43eb5
{{- end -}}

{{/* The login of the installation's storage box, from the Secret recovery-box (externalsecret-recovery-box.yaml),
     as the environment of a step of `recovery-export`, and the rclone remote `box:` made of it, whose root is
     the login's root. The password reaches `rclone obscure` on standard input, never as an argument. */}}
{{- define "consumer-build.recoveryBoxEnv" -}}
- name: STORAGE_BOX_HOST
  valueFrom: { secretKeyRef: { name: recovery-box, key: host } }
- name: STORAGE_BOX_USER
  valueFrom: { secretKeyRef: { name: recovery-box, key: user } }
- name: STORAGE_BOX_PASSWORD
  valueFrom: { secretKeyRef: { name: recovery-box, key: password } }
{{- end -}}
{{- define "consumer-build.recoveryBoxLogin" -}}
export RCLONE_CONFIG_BOX_TYPE=sftp
export RCLONE_CONFIG_BOX_HOST="${STORAGE_BOX_HOST}"
export RCLONE_CONFIG_BOX_USER="${STORAGE_BOX_USER}"
RCLONE_CONFIG_BOX_PASS="$(printf '%s' "${STORAGE_BOX_PASSWORD}" | rclone obscure -)"
export RCLONE_CONFIG_BOX_PASS
{{- end -}}

{{/* The steps of `recovery-export`, the task of every run that writes the recovery folder of the owner's
     master. Every call on the storage box names the folder <global.domain>/recovery below the login's root, or
     a path below it, and never the root, which holds the installation's other backups beside it. plan names
     the run's archives with files/recovery-folder.sh. present makes the folder where it is missing, which the
     first run on a box does, lists what it holds and fetches every engine archive among them again, because a
     release built again under its tag has other bytes, and check then refuses it. copy reads every archive
     the box lacks from the owned registry without a login. check holds every archive the run wrote or fetched
     to the test the driver puts it to, so a folder the driver would refuse is never written. upload copies
     what the box lacks, never over a file that stands and never with a sync, and reads the list back. The
     login recovery-box stands in present and upload alone, which run rclone and no code of a repository.
     Keys: root, the chart's context; dir, the folder the run works in; volume, true where that folder is
     the task's volume `recovery` and not a workspace; tree, true where files/recovery-folder.sh is the
     tree's at /workspace/source and not this chart's; digests, the ansiwise.sha256 check holds an engine
     to, or -; env, the environment of plan; plan, the lines that write <dir>/recovery.plan. */}}
{{- define "consumer-build.recoveryExportSteps" -}}
{{- $dir := .dir -}}
{{- $box := printf "box:%s/recovery" (required "consumer-build: global.domain is required (clusters/active/<fqdn>.yaml, the fqdn of the cluster this build plane runs on — the recovery folder is <fqdn>/recovery/ below the storage box login's root)" .root.Values.global.domain) -}}
{{- $lib := ". clusters/inventories/consumer-build/files/recovery-folder.sh" -}}
{{- if not .tree }}{{ $lib = .root.Files.Get "files/recovery-folder.sh" }}{{ end -}}
- name: plan
  image: {{ include "consumer-build.toolsImage" .root }}
  {{- if .tree }}
  workingDir: /workspace/source
  {{- end }}
  {{- with .env }}
  env:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- if .volume }}
  volumeMounts: [{ name: recovery, mountPath: {{ $dir }} }]
  {{- end }}
  computeResources:
    requests: { cpu: 50m, memory: 64Mi }
    limits: { cpu: 500m, memory: 256Mi }
  script: |
    #!/usr/bin/env bash
    set -euo pipefail
{{ $lib | indent 4 }}
{{ .plan | indent 4 }}
    echo "recovery: this run names $(wc -l < {{ $dir }}/recovery.plan) archives for the recovery folder"
- name: present
  image: {{ include "consumer-build.rcloneImage" .root }}
  env:
    {{- include "consumer-build.recoveryBoxEnv" .root | nindent 4 }}
  {{- if .volume }}
  volumeMounts: [{ name: recovery, mountPath: {{ $dir }} }]
  {{- end }}
  computeResources:
    requests: { cpu: 50m, memory: 64Mi }
    limits: { cpu: 500m, memory: 256Mi }
  script: |
    #!/bin/sh
    set -eu
{{ include "consumer-build.recoveryBoxLogin" .root | indent 4 }}
    rclone mkdir {{ $box }}
    rclone lsf --recursive --files-only {{ $box }}/ > {{ $dir }}/recovery.present
    mkdir -p {{ $dir }}/recovery
    # An engine's archive that stands is fetched, so `check` holds it to this run's digests: an engine is named by
    # its release alone, and other bytes under that name stop the run. A build's tag names its commit, and the release run's probe holds it there.
    while read -r path name digest; do
      case "${path}" in
        engine/*) if grep -qxF "${path}" {{ $dir }}/recovery.present; then rclone copyto "{{ $box }}/${path}" "{{ $dir }}/recovery/${path}"; fi ;;
      esac
    done < {{ $dir }}/recovery.plan
    echo "recovery: the storage box holds $(wc -l < {{ $dir }}/recovery.present) files of the recovery folder"
- name: copy
  image: {{ include "consumer-build.skopeoImage" .root }}
  {{- if .volume }}
  volumeMounts: [{ name: recovery, mountPath: {{ $dir }} }]
  {{- end }}
  computeResources:
    requests: { cpu: 200m, memory: 256Mi }
    limits: { cpu: "1", memory: 512Mi }
  script: |
    #!/usr/bin/env bash
    set -euo pipefail
    recovery_copy() { # <plan> <the files the box holds> <the folder to write into>: every archive the box lacks, read without a login
      local path name digest source written=0 kept=0
      while read -r path name digest; do
        if grep -qxF "${path}" "$2"; then
          kept=$((kept + 1))
          continue
        fi
        source="docker://${name}"
        [ "${digest}" = - ] || source="docker://${name%:*}@${digest}"
        mkdir -p "$3/$(dirname "${path}")"
        if ! skopeo copy --quiet --all --preserve-digests --retry-times 3 --src-no-creds "${source}" "oci-archive:$3/${path}:${name}"; then
          echo "recovery: FAIL — ${source} could not be written to ${path}" >&2
          return 1
        fi
        written=$((written + 1))
      done < "$1"
      echo "recovery: ${written} archives written, ${kept} already on the storage box"
    }
    recovery_copy {{ $dir }}/recovery.plan {{ $dir }}/recovery.present {{ $dir }}/recovery
- name: check
  image: {{ include "consumer-build.toolsImage" .root }}
  {{- if .tree }}
  workingDir: /workspace/source
  {{- end }}
  {{- if .volume }}
  volumeMounts: [{ name: recovery, mountPath: {{ $dir }} }]
  {{- end }}
  computeResources:
    requests: { cpu: 100m, memory: 64Mi }
    limits: { cpu: "1", memory: 256Mi }
  script: |
    #!/usr/bin/env bash
    set -euo pipefail
{{ $lib | indent 4 }}
    # The test the driver puts every archive to before it imports one, so a folder it would refuse is never written.
    count=0
    while read -r path name digest; do
      [ -f "{{ $dir }}/recovery/${path}" ] || continue
      if ! held="$(recovery_archive_digest {{ $dir }}/recovery "${path}" "${name}" "${digest}" {{ .digests }} {{ $dir }}/recovery.unpacked)"; then
        echo "recovery: FAIL — ${path} is not the archive of ${name} this run names" >&2
        exit 1
      fi
      count=$((count + 1))
      echo "recovery: ${path} holds ${name} at ${held}"
    done < {{ $dir }}/recovery.plan
    echo "recovery: ${count} archives this run wrote or fetched hold their image"
- name: upload
  image: {{ include "consumer-build.rcloneImage" .root }}
  env:
    {{- include "consumer-build.recoveryBoxEnv" .root | nindent 4 }}
  {{- if .volume }}
  volumeMounts: [{ name: recovery, mountPath: {{ $dir }} }]
  {{- end }}
  computeResources:
    requests: { cpu: 100m, memory: 128Mi }
    limits: { cpu: "1", memory: 512Mi }
  script: |
    #!/bin/sh
    set -eu
{{ include "consumer-build.recoveryBoxLogin" .root | indent 4 }}
    # COPY, NEVER SYNC, AND NEVER OVER A FILE THAT STANDS: an archive is named after what it holds.
    rclone copy --ignore-existing --quiet {{ $dir }}/recovery {{ $box }}/
    rclone lsf --recursive --files-only {{ $box }}/ > {{ $dir }}/recovery.present
    missing=0
    while read -r path name digest; do
      grep -qxF "${path}" {{ $dir }}/recovery.present || { echo "recovery: FAIL — ${path} is not on the storage box after the copy" >&2; missing=$((missing + 1)); }
    done < {{ $dir }}/recovery.plan
    [ "${missing}" = 0 ]
    echo "recovery: the storage box holds all $(wc -l < {{ $dir }}/recovery.plan) archives of this run"
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
