{{/*
The per-slave coordinates the env list below is composed from, each guarded where
it is read.

WHY THEY ARE NAMED TEMPLATES AND NOT WRITTEN INTO THE VALUES DIRECTLY.
charts/deployment renders the env list as `tpl (toYaml .Values.env) $`, and
toYaml FOLDS a scalar longer than eighty columns at a space. A fold that lands
inside the quoted message of a `required` splits a string literal across two
lines and the go template no longer parses at all — the render dies with
"unterminated quoted string" and says nothing about the value that was missing.
A named template is never folded, so the guard is free to name the field.

The values.yaml env entries therefore call these with `$`: inside the sub-chart
that renders the list, `$` is that sub-chart's root context, whose .Values
carries the globals — which is where the slaves ApplicationSet injects the three
fields (see the `global` note in values.yaml).
*/}}

{{/* The slave's short name, which is also its namespace on the master. */}}
{{- define "dbgate.slaveName" -}}
{{- required "global.slave.name is required (cluster-map field name, injected by argocd/apps/slaves-appset.yaml)" .Values.global.slave.name -}}
{{- end }}

{{/*
The address the master dials this slave on. Nothing on the slave publishes
mongodb or redis there — apps/mongodb and apps/redis both serve inside their own
cluster and neither carries an Ingress — so both connections fail until a slave
publishes the two ports on a plain-TCP entry point bound to this address.
*/}}
{{- define "dbgate.slaveAddress" -}}
{{- required "global.slave.apiHost is required (cluster-map field apiHost, injected by argocd/apps/slaves-appset.yaml)" .Values.global.slave.apiHost -}}
{{- end }}

{{/*
The master's fqdn — the right half of this instance's own host. Read by the
Ingress rather than by the env list, and guarded here so all three per-slave
fields are read in one place.
*/}}
{{- define "dbgate.masterFqdn" -}}
{{- required "global.slave.masterFqdn is required (cluster-map field master, injected by argocd/apps/slaves-appset.yaml)" .Values.global.slave.masterFqdn -}}
{{- end }}
