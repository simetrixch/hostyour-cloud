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
The "owner/repo" of the platform repository, for the env GITHUB_REPO: `github.repo` where an installation
sets it, else the owner and name in global.platformUrl, so the platform repository is named once and
GITHUB_REPO and PLATFORM_REPO_URL cannot disagree. Empty only where the platform URL is.
*/}}
{{- define "manager.platformRepo" -}}
{{- .Values.github.repo | default (regexReplaceAll "^https://[^/]+/" (.Values.global.platformUrl | default "") "" | trimSuffix ".git") -}}
{{- end }}

{{/*
FORGEJO_PACKAGE_SCOPES: the organisation=scope pairs of forgejo.packageScopes, comma separated, in the
order of the organisations' names.
*/}}
{{- define "manager.forgejoPackageScopes" -}}
{{- $pairs := list -}}
{{- range $organisation, $scope := .Values.forgejo.packageScopes }}{{- $pairs = append $pairs (printf "%s=%s" $organisation $scope) -}}{{- end -}}
{{- join "," $pairs -}}
{{- end }}
