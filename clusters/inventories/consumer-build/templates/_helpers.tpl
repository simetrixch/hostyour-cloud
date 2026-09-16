{{/*
consumer-build.unitName — the unit this render belongs to, from the stamped
registration values (UNIT mode). `required` guards a render where the fan-out
forgot the valuesObject: every unit-mode template keys on this name, so an
empty one must fail the render, not produce anonymous objects.
*/}}
{{- define "consumer-build.unitName" -}}
{{- required "consumer-build: unit.name is required (stamped by the fan-out ApplicationSet)" .Values.unit.name -}}
{{- end -}}

{{/*
consumer-build.builds — the ATTESTED builds[] of the unit, decoded from the
JSON string the fan-out stamps (unit.buildsJson). These are the build NAMES
from registrations/<unit>/build.yaml — under flat image naming each name IS
the zot repo the release pushes to.
*/}}
{{- define "consumer-build.builds" -}}
{{- required "consumer-build: unit.buildsJson is required (stamped by the fan-out ApplicationSet)" .Values.unit.buildsJson | fromJsonArray | toJson -}}
{{- end -}}

{{/*
consumer-build.repoOwner — the organisation that owns the unit's repository, read off
unit.repoURL (https://github.com/<owner>/<repo>.git). It is the npm scope the unit's private
packages are published under: GitHub Packages files an organisation's packages under its login
and no other, so the scope is a fact of the registration and never a value of this chart.
*/}}
{{- define "consumer-build.repoOwner" -}}
{{- $url := required "consumer-build: unit.repoURL is required (stamped by the fan-out ApplicationSet)" .Values.unit.repoURL -}}
{{- $owner := regexReplaceAll "^https://github\\.com/([^/]+)/[^/]+$" $url "${1}" -}}
{{- if eq $owner $url }}{{ fail (printf "consumer-build: unit.repoURL %q is not https://github.com/<owner>/<repo>[.git], and the build's npm scope is read off its owner" $url) }}{{ end -}}
{{- $owner -}}
{{- end -}}
