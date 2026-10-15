# Decides, from the PipelineRuns that carry image-builder.io/consumer or image-builder.io/publish (the
# labels their TriggerTemplates give them), which waiting release and publish runs start now and which
# wait, and emits one patch per run that has to change. The caller passes the number of releases that run
# at once as --argjson max (releaseQueue.maxRunning, 2). The build plane is one node, and releases beyond
# what its memory and its pod limit hold filled it until no task pod could start.
# A release is one release tag in one build namespace; its stages run together. A publish run (the npm
# packages of a release tag, consumer-build pipeline-publish.yaml) is a release of its own key,
# `<namespace>/<tag> publish`. A release starts when fewer than max releases run and no release of its
# unit, which is its build namespace, runs or starts: two releases of one unit, a publish run among them,
# never build side by side, and a third unit waits for a free slot. The waiting runs are taken oldest
# first, so a unit whose release waits for its own unit's release does not hold a slot back from a younger
# release of another unit. A waiting run of a release that already runs starts at once, because a release
# has one run per stage. Starts come first, so a note that cannot be written never holds a start back.
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
    {open: ($running | map(releaseKey) | inOrder),
     holder: ($running | map({key: unitOf, value: releaseKey}) | from_entries),
     decisions: []};
    ($run | releaseKey) as $key | ($run | unitOf) as $unit
    | if any(.open[]; . == $key) then
        .decisions += [{run: $run, key: $key}]
      elif (.open | length) < $max and (.holder | has($unit) | not) then
        .open += [$key] | .holder[$unit] = $key | .decisions += [{run: $run, key: $key}]
      else
        .decisions += [{run: $run, key: $key,
          behind: (if .holder | has($unit) then .holder[$unit] else (.open | join(" and ")) end)}]
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
