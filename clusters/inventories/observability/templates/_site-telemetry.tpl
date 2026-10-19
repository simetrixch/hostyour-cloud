{{- /* The one label pair the Deployment selects its pods by, the Service and the NetworkPolicy select them by too. */ -}}
{{- define "site-telemetry.selectorLabels" -}}
app.kubernetes.io/name: site-telemetry
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
