{{/*
rbac.grants — emit, for every grant in the caller-supplied list, a Role +
RoleBinding (when the grant carries a non-empty `namespace`) OR a ClusterRole +
ClusterRoleBinding (empty/absent `namespace` ⇒ cluster-scoped), each bound to
the SINGLE shared `subject` (a ServiceAccount, possibly in another namespace).
Standard labels come from the caller's chart context (`root`) via common.labels.

One building block for "RBAC with the workload": a workload chart ships its own
grants from its own templates instead of a satellite RBAC app.

Call shape (from a consuming chart's templates/rbac.yaml):

  {{- include "rbac.grants" (dict
       "root"    $
       "subject" (dict "name" "<sa>" "namespace" "<sa-ns>")
       "grants"  (list
         (dict "name" "role-a" "namespace" "ns-x" "rules" (list
           (dict "apiGroups" (list "") "resources" (list "secrets") "verbs" (list "get"))))
         (dict "name" "clusterrole-b" "rules" (list                    # no namespace ⇒ cluster-scoped
           (dict "apiGroups" (list "") "resources" (list "namespaces") "verbs" (list "get"))))
       )) }}

Each grant dict: `name` (required); `namespace` (empty ⇒ cluster-scoped);
`rules` (raw RBAC rules, including optional `resourceNames`).
*/}}
{{- define "rbac.grants" -}}
{{- $root := .root -}}
{{- $subject := .subject -}}
{{- range $grant := .grants }}
{{- if $grant.namespace }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ $grant.name }}
  namespace: {{ $grant.namespace }}
  labels:
    {{- include "common.labels" $root | nindent 4 }}
rules:
  {{- toYaml $grant.rules | nindent 2 }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $grant.name }}
  namespace: {{ $grant.namespace }}
  labels:
    {{- include "common.labels" $root | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: {{ $grant.name }}
subjects:
  - kind: ServiceAccount
    name: {{ $subject.name }}
    namespace: {{ $subject.namespace }}
{{- else }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: {{ $grant.name }}
  labels:
    {{- include "common.labels" $root | nindent 4 }}
rules:
  {{- toYaml $grant.rules | nindent 2 }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ $grant.name }}
  labels:
    {{- include "common.labels" $root | nindent 4 }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: {{ $grant.name }}
subjects:
  - kind: ServiceAccount
    name: {{ $subject.name }}
    namespace: {{ $subject.namespace }}
{{- end }}
{{- end }}
{{- end }}
