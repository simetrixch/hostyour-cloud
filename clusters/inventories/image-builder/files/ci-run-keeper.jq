# Decides what happens to the ci runs, which are the PipelineRuns that carry image-builder.io/ci. The caller
# passes the cap as --argjson max, the time as --argjson now (seconds since the epoch), what the remotes
# answered as --slurpfile remote, and what to print as --arg mode: `asks` prints the remotes that the keeper
# has to read first, `decide` prints the changes. Changes come out in this order, so that a change which
# cannot be written never holds back one that matters more:
#
#   cancel  a run that has not finished and has a newer run of the same branch in its namespace, because
#           the newer push replaces it; a run that waits for a slot is cancelled the same way and never
#           started. A run without the branch annotation is never grouped, and the newest run of a branch
#           is never cancelled. Two runs created in the same second are not ordered, so neither cancels
#           the other. A run that has started is cancelled gracefully (CancelledRunFinally), so its
#           finally tasks still run and set the commit status that its first task set to pending; a run
#           that waits has set none, and is cancelled outright (Cancelled). The same patch writes the
#           annotation image-builder.io/cancelled-by on the run: the commit and the run of the newest push
#           to its branch, so the cancelled run says by which push it was replaced.
#   cancel  a run that has not finished and is not replaced, whose `ci/` branch no longer exists on its
#           remote, in the same two ways, with the annotation image-builder.io/branch-deleted holding the
#           branch. Deleting a branch sends no push, so nothing else would end its runs. The remote is the
#           git-url of the run, as the keeper read it: the default branch and the `ci/` branches there.
#           The trigger admits a push of the default branch or of a `ci/` branch and nothing else, so a
#           run of any other branch is a run of the default branch and is never judged; a branch that is
#           the default branch of its remote is never judged either, and neither is a run that is
#           younger than `grace` seconds, which the remote may not list yet, nor a run whose remote the
#           keeper did not read. A cancelled run of this kind is never started and holds no slot.
#   start   the oldest waiting runs (spec.status PipelineRunPending), as many as there are free slots,
#           where a slot is held by every ci run that has started and not finished, whatever its pods
#           wait for. Every ci run is created waiting, because ci pods at the same moment overran the
#           memory of the build node. A build namespace has one ci pod at a time (the quota of its unit),
#           so a namespace with a started run gets no start, and of the others only the oldest waiting
#           run of each is taken: a second run of one unit would hold a slot without running a pod.
#   note    on each run that stays waiting, the annotation image-builder.io/queued-behind with the reason:
#           a ci run of its unit runs or starts, or else all slots are in use.
#   delete  in each build namespace, every finished run but the newest 20. The newest twenty keep recent
#           failures readable in the Tekton Dashboard.
#
# A run without the ci label (a release run among them) is never looked at, and a run that has not
# finished is never deleted.

def keep: 20;
def grace: 120;
def succeeded: [(.status.conditions // [])[] | select(.type == "Succeeded") | .status][0] // "";
def isDone: succeeded == "True" or succeeded == "False";
def isPending: .spec.status == "PipelineRunPending";
def branch: .metadata.annotations["image-builder.io/ci-branch"];
def created: .metadata.creationTimestamp;
def commit: [.spec.params[] | select(.name == "commit") | .value][0];
def gitUrl: [(.spec.params // [])[] | select(.name == "git-url") | .value][0] // "";
def githubClone: test("^https://github[.]com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+[.]git$");
def isCiBranch: (branch // "") | startswith("ci/");
def isOld: ($now - (created | fromdateiso8601)) >= grace;
def cancelStatus: if isPending then "Cancelled" else "CancelledRunFinally" end;
def nameOf: .metadata.namespace + "/" + .metadata.name;
def pushOf: "\(commit) (\(.metadata.name))";
def queuedBehind: .metadata.annotations["image-builder.io/queued-behind"] // "";
def identity: {namespace: .metadata.namespace, name: .metadata.name};

[.items[] | select(.metadata.labels["image-builder.io/ci"] != null)] as $runs
| [$runs[] | select(branch != null)
   | select(isDone | not) | select(.spec.status == null or isPending)] as $open
| ([$runs[] | select(branch != null)]
   | group_by([.metadata.namespace, branch])
   | map(sort_by(created, .metadata.name) | last | {key: (.metadata.namespace + "/" + branch), value: .})
   | from_entries) as $newest
| [$open[] | select(created < ($newest[.metadata.namespace + "/" + branch] | created))] as $replaced
| ($replaced | map(nameOf)) as $replacedNames
| [$open[] | select(isCiBranch and isOld) | select(nameOf as $name | $replacedNames | index($name) | not)] as $judged
| ($remote[0]) as $remoteBranches
| [$judged[] | branch as $branch
   | select(gitUrl as $url | $remoteBranches[$url] != null)
   | select(gitUrl as $url | $remoteBranches[$url] | (.default != $branch) and ((.branches | index($branch)) == null))] as $gone
| ($gone | map(nameOf)) as $goneNames
| [$runs[] | select((isDone | not) and (isPending | not))] as $started
| ($started | length) as $running
| ($started | map(.metadata.namespace) | unique) as $busy
| ([$max - $running, 0] | max) as $free
| ([$runs[] | select(isPending and (isDone | not))
     | select(nameOf as $name | ($replacedNames + $goneNames) | index($name) | not)]
   | sort_by(created, .metadata.name)) as $waiting
| ($waiting | group_by(.metadata.namespace) | map(.[0])
   | map(select(.metadata.namespace as $namespace | any($busy[]; . == $namespace) | not))
   | sort_by(created, .metadata.name)[:$free]) as $startable
| ($startable | map(.metadata.namespace)) as $starting
| ($startable | map(nameOf)) as $startingNames
| "all \($max) ci slots are in use" as $slotsReason
| "a ci run of this unit runs" as $unitReason
| [$replaced[]
   | ($newest[.metadata.namespace + "/" + branch] | pushOf) as $by
   | identity + {verb: "cancel", type: "merge",
      patch: {spec: {status: cancelStatus},
              metadata: {annotations: {"image-builder.io/cancelled-by": $by}}},
      say: "cancelled \(nameOf): a newer push to \(branch) replaces it, \($by)"}] as $cancels
| [$gone[]
   | identity + {verb: "cancel", type: "merge",
      patch: {spec: {status: cancelStatus},
              metadata: {annotations: {"image-builder.io/branch-deleted": branch}}},
      say: "cancelled \(nameOf): its branch \(branch) no longer exists on \(gitUrl)"}] as $goneCancels
| [$startable[]
   | identity + {verb: "patch", type: "json",
      patch: ([{op: "remove", path: "/spec/status"}]
        + (if queuedBehind != "" then [{op: "remove", path: "/metadata/annotations/image-builder.io~1queued-behind"}] else [] end)),
      say: "started \(.metadata.namespace)/\(.metadata.name): a ci slot is free"}] as $starts
| [$waiting[] | select(nameOf as $name | any($startingNames[]; . == $name) | not)
   | .metadata.namespace as $namespace
   | (if any($busy[]; . == $namespace) or any($starting[]; . == $namespace) then $unitReason else $slotsReason end) as $reason
   | select(queuedBehind != $reason)
   | identity + {verb: "patch", type: "merge",
      patch: {metadata: {annotations: {"image-builder.io/queued-behind": $reason}}},
      say: "\(.metadata.namespace)/\(.metadata.name) waits: \($reason)"}] as $notes
| ([$runs[] | select(isDone)]
   | group_by(.metadata.namespace)
   | map(sort_by(created, .metadata.name) | reverse | .[keep:][]
         | identity + {verb: "delete", say: "deleted \(.metadata.namespace)/\(.metadata.name), created \(created)"})
   | flatten) as $deletes
| ([$judged | group_by(gitUrl)[]
     | {url: (.[0] | gitUrl), runs: (map(nameOf) | sort)}
     | if .url | githubClone then {ask: .url, runs} else {refuse: .url, runs} end]) as $asks
| (if $mode == "asks" then $asks else $cancels + $goneCancels + $starts + $notes + $deletes end)[]
