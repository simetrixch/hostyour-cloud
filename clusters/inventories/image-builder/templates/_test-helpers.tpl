{{- define "image-builder.testCode" -}}
{{- $common := .root.Files.Get "files/test-contract.mjs" | toJson -}}
{{- $worker := .root.Files.Get .file | toJson -}}
{{- $name := base .file -}}
{{- printf "import {writeFileSync, mkdtempSync} from 'node:fs';\nconst directory = mkdtempSync('/tmp/hostyour-runner-');\nwriteFileSync(directory + '/test-contract.mjs', %s, {mode: 384});\nwriteFileSync(directory + '/%s', %s, {mode: 384});\nawait import('file://' + directory + '/%s');\n" $common $name $worker $name -}}
{{- end -}}
{{- define "image-builder.testRunnerDigest" -}}
{{- printf "sha256:%s" (include "image-builder.testCode" (dict "root" . "file" "files/test-suites.mjs") | sha256sum) -}}
{{- end -}}

{{- define "image-builder.reporterPod" -}}
{{- $root := .root -}}
{{- $reporter := $root.Values.digitaTests.reporter -}}
serviceAccountName: {{ $reporter.serviceAccountName }}
automountServiceAccountToken: true
restartPolicy: {{ ternary "Never" "Always" .once }}
{{- if .once }}
# A RWO state volume must mount on the node already holding the reporter.
affinity:
  podAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: {{ $reporter.name }}
            app.kubernetes.io/component: reporter
        topologyKey: kubernetes.io/hostname
{{- end }}
securityContext:
  runAsNonRoot: true
  runAsUser: 65532
  runAsGroup: 65532
  fsGroup: 65532
  seccompProfile: {type: RuntimeDefault}
containers:
  - name: reporter
    image: {{ $root.Values.tests.nodeImage | quote }}
    command: [node, /reporter-code/test-reporter.mjs]
{{- if .once }}
    args: [--once]
{{- else }}
    ports:
      - {name: http, containerPort: {{ $reporter.port }}}
    readinessProbe:
      httpGet: {path: /readyz, port: http}
      periodSeconds: 10
    livenessProbe:
      httpGet: {path: /readyz, port: http}
      initialDelaySeconds: 30
      periodSeconds: 20
{{- end }}
    env:
      - {name: REPORTER_APP_ID, value: {{ $reporter.appId | quote }}}
      - {name: REPORTER_INSTALLATION_ID, value: {{ $reporter.installationId | quote }}}
      - {name: REPORTER_PORT, value: {{ $reporter.port | quote }}}
      - {name: TEST_NODE_IMAGE, value: {{ $root.Values.tests.nodeImage | quote }}}
      - name: TEST_RUNNER_DIGEST
        value: {{ include "image-builder.testRunnerDigest" $root | quote }}
      - name: TEST_LOG_URL
        value: {{ printf "https://tekton.%s" $root.Values.global.domain | quote }}
    resources:
      requests: {cpu: 50m, memory: 128Mi}
      limits: {cpu: 250m, memory: 256Mi}
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: {drop: [ALL]}
    volumeMounts:
      - {name: code, mountPath: /reporter-code, readOnly: true}
      - {name: key, mountPath: /reporter-key, readOnly: true}
      - {name: state, mountPath: /reporter-state}
volumes:
  - name: code
    configMap: {name: {{ $reporter.name }}-code}
  - name: key
    secret: {secretName: {{ $reporter.name }}, defaultMode: 288}
  - name: state
    persistentVolumeClaim: {claimName: {{ $reporter.name }}-state}
{{- end -}}
