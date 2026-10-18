{{/*
The plugins the pinned manager image activates, as its PLUGINS key: the `plugins` of the manager's
builds[] entry, which the Manager release writes in the same commit as the image tag. A release
therefore switches the image and the plugins it names together. An entry without `plugins` renders
no PLUGINS key, and the core then runs alone.
*/}}
{{- define "manager.plugins" -}}
{{- range .Values.builds }}{{- if eq .name "manager" }}{{- .plugins | default "" }}{{- end }}{{- end -}}
{{- end }}

{{/*
The "owner/repo" of the platform repository, for the env GITHUB_REPO: the owner and name in
global.platformUrl, which is where the platform repository is named. `github.repo` is no second name
for it: where an installation still sets it, it must name the same repository, or the render fails
here, because a Manager given two repositories refuses to start. Empty only where the platform URL is.
*/}}
{{- define "manager.platformRepo" -}}
{{- $derived := regexReplaceAll "^https://[^/]+/" (.Values.global.platformUrl | default "") "" | trimSuffix ".git" -}}
{{- if and .Values.github.repo (ne .Values.github.repo $derived) -}}
{{- fail (printf "manager: github.repo (%s) names another repository than global.platformUrl (%s): the platform repository is named once, in global.platformUrl — set that and remove github.repo" .Values.github.repo $derived) -}}
{{- end -}}
{{- $derived -}}
{{- end }}
