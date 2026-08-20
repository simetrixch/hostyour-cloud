{{/*
WHAT EACH MODE MEANS, stated ONCE for every template in this chart.

`unit-mongodb.replicas` — the member count. This is not a free number: it is part
of what the word means, and the Controller's quota table multiplies the mongodb
row by the SAME count when it prices the unit
(hostyour-manager/shared/unit-size.ts, MONGODB_MEMBERS). A render and a ceiling
that disagreed would let a unit start more members than its namespace admits, and
the quota would refuse the last pod with no explanation at the size it was sold.

`unit-mongodb.isReplicaSet` — whether --replSet, the keyfile, the rs-init Job and
the PodDisruptionBudget are rendered at all. A `standalone` is a TRUE standalone,
not a one-member set: MongoDB serves no multi-document transactions from one, and
that is the difference the consumer chose. Rendering a one-member replica set
would serve them and make the word a lie.

An unknown mode FAILS the render. A silent fall back to one member would hand a
consumer that asked for a replica set a database with no transactions, which is
the one failure this chart exists to make impossible.
*/}}

{{- define "unit-mongodb.replicas" -}}
{{- if eq .Values.mongodb.mode "replicaset" -}}3
{{- else if eq .Values.mongodb.mode "standalone" -}}1
{{- else -}}
{{- fail (printf "mongodb.mode %q — the modes this chart renders are \"standalone\" (one mongod, no transactions) and \"replicaset\" (three members). A unit on the cluster's shared replica set renders no instance at all and must not include this chart." .Values.mongodb.mode) -}}
{{- end -}}
{{- end -}}

{{- define "unit-mongodb.isReplicaSet" -}}
{{- if eq .Values.mongodb.mode "replicaset" -}}true{{- end -}}
{{- end -}}
