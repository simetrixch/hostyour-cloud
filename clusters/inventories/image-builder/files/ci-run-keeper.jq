# Decides what happens to the ci runs, which are the PipelineRuns that carry image-builder.io/ci. The
# caller passes the cap as --argjson max. Changes come out in this order, so that a change which cannot
# be written never holds back one that matters more:
#
#   cancel  a run that has not finished and has a newer run of the same branch in its namespace, because
#           the newer push replaces it; a run that waits for a slot is cancelled the same way and never
#           started. A run without the branch annotation is never grouped, and the newest run of a branch
#           is never cancelled. Two runs created in the same second are not ordered, so neither cancels
#           the other.
#   start   the oldest waiting runs (spec.status PipelineRunPending), as many as there are free slots,
#           where a slot is held by every ci run that has started and not finished, whatever its pods
#           wait for. Every ci run is created waiting, because ci pods at the same moment overran the
#           memory of the build node.
#   note    on each run that stays waiting, the annotation image-builder.io/queued-behind with the reason.
#   delete  in each build namespace, every finished run but the newest 20. Every run holds a workspace
#           claim of workspaces.sourceSize until the run is deleted, and the newest twenty keep recent
#           failures readable in the Tekton Dashboard.
#
# A run without the ci label (a release run among them) is never looked at, and a run that has not
# finished is never deleted.

def keep: 20;
def succeeded: [(.status.conditions // [])[] | select(.type == "Succeeded") | .status][0] // "";
def isDone: succeeded == "True" or succeeded == "False";
def isPending: .spec.status == "PipelineRunPending";
def branch: .metadata.annotations["image-builder.io/ci-branch"];
def created: .metadata.creationTimestamp;
def queuedBehind: .metadata.annotations["image-builder.io/queued-behind"] // "";
def identity: {namespace: .metadata.namespace, name: .metadata.name};

[.items[] | select(.metadata.labels["image-builder.io/ci"] != null)] as $runs
| [$runs[] | select(branch != null)
   | select(isDone | not) | select(.spec.status == null or isPending)] as $open
| ([$runs[] | select(branch != null)]
   | group_by([.metadata.namespace, branch])
   | map(.[0] as $first | {key: ($first.metadata.namespace + "/" + ($first | branch)), value: (map(created) | max)})
   | from_entries) as $newest
| [$open[] | select(created < $newest[.metadata.namespace + "/" + branch])] as $replaced
| ($replaced | map(.metadata.namespace + "/" + .metadata.name)) as $replacedNames
| ([$runs[] | select((isDone | not) and (isPending | not))] | length) as $running
| ([$max - $running, 0] | max) as $free
| ([$runs[] | select(isPending and (isDone | not))
     | select((.metadata.namespace + "/" + .metadata.name) as $name | $replacedNames | index($name) | not)]
   | sort_by(created, .metadata.name)) as $waiting
| "all \($max) ci slots are in use" as $reason
| [$replaced[]
   | identity + {verb: "cancel",
      say: "cancelled \(.metadata.namespace)/\(.metadata.name): a newer push to \(branch) replaces it"}] as $cancels
| [$waiting[:$free][]
   | identity + {verb: "patch", type: "json",
      patch: ([{op: "remove", path: "/spec/status"}]
        + (if queuedBehind != "" then [{op: "remove", path: "/metadata/annotations/image-builder.io~1queued-behind"}] else [] end)),
      say: "started \(.metadata.namespace)/\(.metadata.name): a ci slot is free"}] as $starts
| [$waiting[$free:][] | select(queuedBehind != $reason)
   | identity + {verb: "patch", type: "merge",
      patch: {metadata: {annotations: {"image-builder.io/queued-behind": $reason}}},
      say: "\(.metadata.namespace)/\(.metadata.name) waits: \($reason)"}] as $notes
| ([$runs[] | select(isDone)]
   | group_by(.metadata.namespace)
   | map(sort_by(created, .metadata.name) | reverse | .[keep:][]
         | identity + {verb: "delete", say: "deleted \(.metadata.namespace)/\(.metadata.name), created \(created)"})
   | flatten) as $deletes
| ($cancels + $starts + $notes + $deletes)[]
