{{/*
common.argoSyncGrant — the grant that lets the release pipeline of the unit building an inventory's
images read that inventory's Application once its bump pinned the new tag on the install branch, and
wait until the Application stands on that commit and reports Synced and Healthy, so the release is
live when its pipeline is green: the argo-sync step of
clusters/inventories/consumer-build/templates/pipeline-release.yaml, and its `platform` hits.

EVERY INVENTORY WHOSE values-<stage>.yaml CARRIES `builds` RENDERS IT: the release pins that file on
the books branch and then reads the Application, and a missing grant answers Forbidden, which the
pipeline fails. scripts/platform-argo-sync.test.mjs holds every such inventory to it.

IT STANDS IN NS argocd, beside the Application: the master's own ArgoCD keeps there the Applications
the platform-apps ApplicationSet stamps, `<name>-<stage>`. The caller's project must admit that
namespace.

IT NAMES THE CALLER'S APPLICATION AT EVERY STAGE OF THE CHANNEL TABLE, and nothing beside them.
A release pins the value file of its own stage, and the pipeline reads `<name>-<stage>` for it.
Where the master runs another stage, that Application does not exist, and the pipeline must hear
NotFound, which it logs and passes. A grant on one name alone answers Forbidden for every other
name, and the pipeline fails a Forbidden as a missing grant.

`patch` is absent: a refresh of the Application would deliver nothing, because every source of this
repository in it stands at the commit root-applications last synced. `list` and `watch` are absent:
Kubernetes ignores resourceNames for those two verbs, so either would reach every Application in the
namespace.

The caller's values name `releasedBy`, the unit whose release pipeline builds its images; the grant
binds that unit's `pipeline-sa` in its stage-free build namespace `<unit>-build`.

Call: include "common.argoSyncGrant" .
*/}}
{{- define "common.argoSyncGrant" -}}
{{- $unit := required (printf "%s: releasedBy is required — the unit whose release pipeline builds this inventory's images, bound by this grant" .Chart.Name) .Values.releasedBy }}
{{- $stages := list }}
{{- range $channel, $channelStages := .Values.global.channelStages }}
{{- $stages = concat $stages $channelStages }}
{{- end }}
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: platform-{{ .Chart.Name }}-argo-sync
  namespace: argocd
  labels:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/managed-by: {{ .Release.Service }}
rules:
  - apiGroups:
      - argoproj.io
    resources:
      - applications
    resourceNames:
      {{- range uniq $stages | sortAlpha }}
      - {{ printf "%s-%s" $.Chart.Name . }}
      {{- end }}
    verbs:
      - get
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: platform-{{ .Chart.Name }}-argo-sync
  namespace: argocd
  labels:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/managed-by: {{ .Release.Service }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: platform-{{ .Chart.Name }}-argo-sync
subjects:
  # The account every release PipelineRun of a unit runs as
  # (clusters/inventories/consumer-build/templates/serviceaccount.yaml).
  - kind: ServiceAccount
    name: pipeline-sa
    namespace: {{ printf "%s-build" $unit }}
{{- end }}
