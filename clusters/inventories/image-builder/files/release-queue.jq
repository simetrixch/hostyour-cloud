# Decides, from every PipelineRun that carries image-builder.io/consumer, which waiting release runs
# start now and which wait, and emits one patch per run that has to change. Releases start one at a
# time because the build plane is one node: parallel releases filled it until no task pod could start.
# A release is one release tag in one build namespace; its stages run together. Starts come first,
# so a note that cannot be written never holds a start back.
# It also deletes, in each build namespace, every finished release run but the newest 20, last: every
# run holds a workspace claim until it is deleted, and the newest twenty keep recent releases readable
# in the Tekton Dashboard. A run that waits or runs is never deleted.

def isRelease: (.spec.pipelineRef.name // "") | endswith("-release");
def succeeded: [(.status.conditions // [])[] | select(.type == "Succeeded") | .status][0] // "";
def isDone: succeeded == "True" or succeeded == "False";
def isPending: .spec.status == "PipelineRunPending";
def releaseKey: .metadata.namespace + "/" + ([(.spec.params // [])[] | select(.name == "release-tag") | .value][0] // "");
def keep: 20;
def queuedBehind: .metadata.annotations["image-builder.io/queued-behind"] // "";

[.items[] | select(isRelease) | select(isDone | not)] as $live
| ([.items[] | select(isRelease) | select(isDone)]
   | group_by(.metadata.namespace)
   | map(sort_by(.metadata.creationTimestamp, .metadata.name) | reverse | .[keep:][]
         | {namespace: .metadata.namespace, name: .metadata.name, verb: "delete",
            say: "deleted \(.metadata.namespace)/\(.metadata.name), created \(.metadata.creationTimestamp)"})
   | flatten) as $deletes
| ($live | map(select(isPending | not)) | sort_by(.metadata.creationTimestamp)) as $running
| ($live | map(select(isPending)) | sort_by(.metadata.creationTimestamp)) as $waiting
| (if ($running | length) > 0 then $running else $waiting[:1] end | map(releaseKey)) as $active
| [$waiting[]
| releaseKey as $key
| if any($active[]; . == $key) then
    {namespace: .metadata.namespace, name: .metadata.name, type: "json",
     patch: ([{op: "remove", path: "/spec/status"}]
       + (if queuedBehind != "" then [{op: "remove", path: "/metadata/annotations/image-builder.io~1queued-behind"}] else [] end)),
     say: "started \(.metadata.namespace)/\(.metadata.name) (release \($key))"}
  elif queuedBehind != $active[0] then
    {namespace: .metadata.namespace, name: .metadata.name, type: "merge",
     patch: {metadata: {annotations: {"image-builder.io/queued-behind": $active[0]}}},
     say: "\(.metadata.namespace)/\(.metadata.name) (release \($key)) waits for release \($active[0])"}
  else empty end]
| (sort_by(.type != "json") + $deletes)[]
