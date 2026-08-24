{{/*
App-local helper. The controller's ConfigMap name is referenced by both
configmap.yaml (where it's defined) and deployment.yaml (where it's mounted) —
one place keeps them in sync.
*/}}
{{- define "service-provisioner.scriptConfigMapName" -}}
service-provisioner-script
{{- end -}}
