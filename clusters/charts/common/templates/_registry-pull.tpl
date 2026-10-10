{{/*
common.registryPullExternalSecret — the pull credential of this installation's registry
(common.registryHost), as a kubernetes.io/dockerconfigjson Secret in the caller's namespace.
ESO composes it from the shared app-tier entry <stage>/app/registry, properties pull-user and
pull-password, through the namespace's default SecretStore (global.secretStoreName, rendered by
the caller's secret-store dependency). The Secret carries the same name as the ExternalSecret.

NO PERIODIC READ OF VAULT, the platform-wide delivery rule stated in full in
clusters/charts/external-secret/templates/externalsecret.yaml: a secret arrives on deploy
(OnChange re-syncs when this resource changes) and when the target Secret is deleted, never on a
timer. Putting a new value in front of the pods is three acts: write it into Vault, delete the
target Secret so ESO fetches it, roll the pods.

COMPOSED HERE FROM THE TWO ATOMIC VALUES, not read as a finished document. A store holds values;
a format belongs to whoever needs it. Asking the store for a finished dockerconfigjson asks for
something nothing writes, and every pod that pulls from this registry would wait on a Secret that
never materializes.

The inner braces are RAW ESO syntax: Helm renders this file, so the ESO expressions are quoted
through to be evaluated by ESO and not here.

The namespace's ESO login needs Vault's `external-secrets` role to admit the namespace. The role
admits every namespace labelled hostyour.cloud/workload: "true".

Call: include "common.registryPullExternalSecret" (dict "root" $ "name" "gate-runner-registry-pull")
*/}}
{{- define "common.registryPullExternalSecret" -}}
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ .name }}
  namespace: {{ .root.Release.Namespace }}
  labels:
    app.kubernetes.io/name: {{ .root.Chart.Name }}
    app.kubernetes.io/managed-by: {{ .root.Release.Service }}
spec:
  refreshPolicy: OnChange
  refreshInterval: "0"
  secretStoreRef:
    name: {{ .root.Values.global.secretStoreName }}
    kind: SecretStore
  target:
    name: {{ .name }}
    creationPolicy: Owner
    template:
      engineVersion: v2
      type: kubernetes.io/dockerconfigjson
      data:
        .dockerconfigjson: |-
          {"auths":{"{{ include "common.registryHost" .root }}":{"username":"{{ `{{ .user }}` }}","password":"{{ `{{ .pass }}` }}","auth":"{{ `{{ printf "%s:%s" .user .pass | b64enc }}` }}"}}}
  data:
    - secretKey: user
      remoteRef:
        key: {{ printf "%s/app/registry" .root.Values.global.env }}
        property: pull-user
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
        nullBytePolicy: Ignore
    - secretKey: pass
      remoteRef:
        key: {{ printf "%s/app/registry" .root.Values.global.env }}
        property: pull-password
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
        nullBytePolicy: Ignore
{{- end }}
