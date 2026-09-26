{{/*
The plugins the pinned manager image activates, as its PLUGINS key: the `plugins` of the manager's
builds[] entry, which the Manager release writes in the same commit as the image tag. A release
therefore switches the image and the plugins it names together. An entry without `plugins` renders
no PLUGINS key, and the core then runs alone.
*/}}
{{- define "manager.plugins" -}}
{{- range .Values.builds }}{{- if eq .name "manager" }}{{- .plugins | default "" }}{{- end }}{{- end -}}
{{- end }}
