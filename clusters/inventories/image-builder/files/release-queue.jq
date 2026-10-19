# Decides, from the PipelineRuns that carry image-builder.io/consumer or image-builder.io/publish (the
# labels their TriggerTemplates give them), which waiting release and publish runs start now and which
# wait, and emits one patch per run that has to change. The caller passes the number of runs that run at
# once as --argjson max (releaseQueue.maxRunning, 9). The build plane is one node, and runs beyond what its
# memory and its pod limit hold filled it until no task pod could start.
# Every release run (one per stage of a release tag) and every publish run (the npm packages of a release
# tag, consumer-build pipeline-publish.yaml) takes one slot and is counted on its own, whatever its tag. A
# run starts when fewer than max runs run and no run of its unit, which is its build namespace, runs or
# starts: of one unit only one run builds at a time, whether it is another stage of the same tag, a retry,
# another tag or a publish run, so the stage runs of a release never build side by side and the capacity
# test of consumer-build counts one run's pods per unit. The waiting runs are taken oldest first, so a
# run that waits for its own unit does not hold a slot back from a younger run of another unit. Starts
# come first, so a note that cannot be written never holds a start back.
# It also deletes, in each build namespace, every finished release run but the newest 20, and every
# finished publish run but the newest 20, last: every run holds a workspace claim until it is deleted,
# and the newest twenty keep recent runs readable in the Tekton Dashboard. A run that waits or runs is
# never deleted.

def isRelease: (.spec.pipelineRef.name // "") | endswith("-release");
def isPublish: (.spec.pipelineRef.name // "") | endswith("-publish");
def isQueued: isRelease or isPublish;
def succeeded: [(.status.conditions // [])[] | select(.type == "Succeeded") | .status][0] // "";
def isDone: succeeded == "True" or succeeded == "False";
def isPending: .spec.status == "PipelineRunPending";
def releaseKey: .metadata.namespace + "/" + ([(.spec.params // [])[] | select(.name == "release-tag") | .value][0] // "")
  + (if isPublish then " publish" else "" end);
def keep: 20;
def queuedBehind: .metadata.annotations["image-builder.io/queued-behind"] // "";
def unitOf: .metadata.namespace;
def inOrder: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);

[.items[] | select(isQueued) | select(isDone | not)] as $live
| ([.items[] | select(isQueued) | select(isDone)]
   | group_by([.metadata.namespace, .spec.pipelineRef.name])
   | map(sort_by(.metadata.creationTimestamp, .metadata.name) | reverse | .[keep:][]
         | {namespace: .metadata.namespace, name: .metadata.name, verb: "delete",
            say: "deleted \(.metadata.namespace)/\(.metadata.name), created \(.metadata.creationTimestamp)"})
   | flatten) as $deletes
| ($live | map(select(isPending | not)) | sort_by(.metadata.creationTimestamp)) as $running
| ($live | map(select(isPending)) | sort_by(.metadata.creationTimestamp)) as $waiting
| (reduce $waiting[] as $run (
    {active: ($running | length),
     open: ($running | map(releaseKey) | inOrder),
     holder: ($running | map({key: unitOf, value: releaseKey}) | from_entries),
     decisions: []};
    ($run | releaseKey) as $key | ($run | unitOf) as $unit
    | if (.holder | has($unit)) or .active >= $max then
        .decisions += [{run: $run, key: $key,
          behind: (if .holder | has($unit) then .holder[$unit] else (.open | join(" and ")) end)}]
      else
        .active += 1 | .open = (.open + [$key] | inOrder) | .holder[$unit] = $key | .decisions += [{run: $run, key: $key}]
      end)).decisions as $decisions
| [$decisions[]
| .run as $run | .key as $key | .behind as $behind
| if $behind == null then
    $run | {namespace: .metadata.namespace, name: .metadata.name, type: "json",
     patch: ([{op: "remove", path: "/spec/status"}]
       + (if queuedBehind != "" then [{op: "remove", path: "/metadata/annotations/image-builder.io~1queued-behind"}] else [] end)),
     say: "started \(.metadata.namespace)/\(.metadata.name) (release \($key))"}
  elif ($run | queuedBehind) != $behind then
    $run | {namespace: .metadata.namespace, name: .metadata.name, type: "merge",
     patch: {metadata: {annotations: {"image-builder.io/queued-behind": $behind}}},
     say: "\(.metadata.namespace)/\(.metadata.name) (release \($key)) waits for release \($behind)"}
  else empty end]
| (sort_by(.type != "json") + $deletes)[]
