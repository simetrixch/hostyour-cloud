{{/*
common.mongodRseqEnv and common.mongodRseqLabel — what a mongod pod carries while the platform runs it
with the rseq workaround, and nothing while the switch global.mongod.rseqWorkaround is false.

MongoDB vendors its own TCMalloc, which disagrees with Linux 6.19 through 7.0.13 over restartable
sequences. The official image does not refuse such a kernel: without GLIBC_TUNABLES=glibc.pthread.rseq=1
mongod serves for about half a minute, dies with SIGSEGV and starts again, taking writes in between. The
variable costs allocation performance, so it comes out once the machines run Linux 7.0.14 or later.

THE LABEL IS HOW THE CLUSTER SEES THE WORKAROUND. kube-state-metrics exports it as
kube_pod_labels{label_hostyour_cloud_mongod_rseq_workaround}, and clusters/inventories/mongodb carries the
rule MongoDBRseqWorkaroundMissing, which fires for a pod without it on a machine whose kernel is in that
range, as hostyour_kernel_info (hostyour-deploy, kernel-reading) reads it on the machine. So the switch is
turned off when every machine reads 7.0.14 or later, and the alert says it when one does not.

Both fragments are list or map items for the caller to indent; each is empty with the switch off. A caller
renders them as `{{- with include "common.mongodRseqEnv" . }}` followed by `{{ . | indent N }}`.
*/}}
{{- define "common.mongodRseqEnv" -}}
{{- if required "global.mongod.rseqWorkaround is not set: clusters/platform/values-common.yaml carries it" (dig "mongod" "rseqWorkaround" nil .Values.global) -}}
- name: GLIBC_TUNABLES
  value: "glibc.pthread.rseq=1"
{{- end -}}
{{- end -}}

{{- define "common.mongodRseqLabel" -}}
{{- if required "global.mongod.rseqWorkaround is not set: clusters/platform/values-common.yaml carries it" (dig "mongod" "rseqWorkaround" nil .Values.global) -}}
hostyour.cloud/mongod-rseq-workaround: "true"
{{- end -}}
{{- end -}}
