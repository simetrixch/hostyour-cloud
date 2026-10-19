{{/*
The repository pattern of the Docker Hub sync: the names Docker Hub has, which are <namespace>/<name>, two
segments, and not the ones under the owner's name. zot globs its content prefix with doublestar, which has no
negation, so "any first segment but the owner" is written out: a segment that differs from the owner word at
one position, one that stops short of it, and one that goes on past it.
*/}}
{{- define "registry.dockerHubPrefix" -}}
{{- $owner := splitList "/" .Values.global.buildRegistry | last -}}
{{- $notOwner := list -}}
{{- range $index := until (len $owner) -}}
{{- $at := int $index -}}
{{- $notOwner = append $notOwner (printf "%s[!%s]*" (substr 0 $at $owner) (substr $at (int (add1 $at)) $owner)) -}}
{{- if gt $at 0 -}}{{- $notOwner = append $notOwner (substr 0 $at $owner) -}}{{- end -}}
{{- end -}}
{{- printf "{%s}/*" (join "," (append $notOwner (printf "%s?*" $owner))) -}}
{{- end -}}
