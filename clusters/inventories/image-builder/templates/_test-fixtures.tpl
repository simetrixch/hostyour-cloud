{{- define "image-builder.mongoFixture" -}}
- name: mongo
  image: {{ .Values.tests.mongoImage | quote }}
  command: [/bin/bash]
  args:
    - -ceu
    - |
      # Every directory is an emptyDir owned by this one TaskRun. No service,
      # production address or persistent database volume participates.
      mongod --bind_ip 127.0.0.1 --port 27017 --replSet rs0 --dbpath /data/db --logpath /tmp/mongo.log --fork
      mongosh --quiet --host 127.0.0.1:27017 --eval 'rs.initiate({_id:"rs0",members:[{_id:0,host:"127.0.0.1:27017"}]})'
      for attempt in $(seq 1 120); do
        if mongosh --quiet --host 127.0.0.1:27017 --eval 'if(!db.hello().isWritablePrimary)quit(1)'; then
          mongosh --quiet --host 127.0.0.1:27017 --eval 'db.getSiblingDB("digita_test_fixture").owner.insertOne({_id:"pipeline-run",runID:process.env.DIGITA_TEST_RUN_ID})'
          touch /tmp/fixture-ready
          break
        fi
        sleep 1
      done
      test -f /tmp/fixture-ready
      tail --pid="$(cat /data/db/mongod.lock)" -f /tmp/mongo.log
  env:
    - {name: HOME, value: /tmp}
    - {name: DIGITA_TEST_RUN_ID, value: "$(params.run-id)"}
  readinessProbe:
    exec: {command: [test, -f, /tmp/fixture-ready]}
    periodSeconds: 2
  volumeMounts:
    - {name: mongo-data, mountPath: /data/db}
    - {name: mongo-scratch, mountPath: /tmp}
  securityContext:
    runAsUser: 0
    runAsGroup: 0
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities: {drop: [ALL]}
    seccompProfile: {type: RuntimeDefault}
  computeResources:
    requests: {cpu: 100m, memory: 512Mi}
    limits: {cpu: "1", memory: 1Gi}
{{- end -}}

{{- define "image-builder.redisFixture" -}}
- name: redis
  image: {{ .Values.tests.redisImage | quote }}
  command: [redis-server]
  args: [--bind, 127.0.0.1, --port, "6379", --save, "", --appendonly, "no", --dir, /tmp]
  readinessProbe:
    exec: {command: [redis-cli, -h, 127.0.0.1, ping]}
    periodSeconds: 2
  volumeMounts:
    - {name: redis-scratch, mountPath: /tmp}
  securityContext:
    runAsUser: 1001
    runAsGroup: 1001
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities: {drop: [ALL]}
    seccompProfile: {type: RuntimeDefault}
  computeResources:
    requests: {cpu: 25m, memory: 64Mi}
    limits: {cpu: 250m, memory: 128Mi}
{{- end -}}
