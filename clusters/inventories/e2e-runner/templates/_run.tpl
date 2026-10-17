{{- /*
The parts every Task of this namespace shares, so that a Task which holds a password is not a copy of
another that holds a different one.

Call each with the chart's root context: include "e2e-runner.image" $
*/ -}}

{{- /* The E2E cases image, built inside this installation by the release of digita-testkit and pushed to its own registry, so the ref is composed against common.registryHost, not common.buildRegistry. */ -}}
{{- define "e2e-runner.image" -}}
{{- $builds := dict "root" . "builds" .Values.builds "name" "digita-testkit-e2e" -}}
{{ printf "%s/%s:%s" (include "common.registryHost" .) (include "common.buildImageName" $builds) (include "common.buildTag" $builds) | quote }}
{{- end }}

{{- define "e2e-runner.stepSecurityContext" -}}
runAsNonRoot: true
runAsUser: {{ .Values.run.runAsUser }}
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
readOnlyRootFilesystem: true
{{- end }}

{{- /* Nothing a run writes outlives its pod: the signed-in session goes to memory, and the test output and /tmp to emptyDir volumes. */ -}}
{{- define "e2e-runner.stepVolumeMounts" -}}
- name: tmp
  mountPath: /tmp
- name: signed-in-session
  mountPath: /e2e/packages/e2e/.auth
- name: test-results
  mountPath: /e2e/packages/e2e/test-results
{{- end }}

{{- define "e2e-runner.volumes" -}}
- name: tmp
  emptyDir: {}
- name: signed-in-session
  emptyDir:
    medium: Memory
- name: test-results
  emptyDir: {}
{{- end }}
