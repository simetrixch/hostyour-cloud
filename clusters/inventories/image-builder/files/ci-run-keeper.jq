# Decides what happens to the ci runs, which are the PipelineRuns that carry image-builder.io/ci:
#
#   cancel  a run that has not finished and has a newer run of the same branch in its namespace, because
#           the newer push replaces it. A run without the branch annotation is never grouped, and the
#           newest run of a branch is never cancelled. Two runs created in the same second are not
#           ordered, so neither cancels the other.
#   delete  in each build namespace, every finished run but the newest 20. Every run holds a workspace
#           claim of workspaces.sourceSize until the run is deleted, and the newest twenty keep recent
#           failures readable in the Tekton Dashboard.
#
# A run without the ci label (a release run among them) is never looked at, and a run that has not
# finished is never deleted.

def keep: 20;
def succeeded: [(.status.conditions // [])[] | select(.type == "Succeeded") | .status][0] // "";
def isDone: succeeded == "True" or succeeded == "False";
def branch: .metadata.annotations["image-builder.io/ci-branch"];
def created: .metadata.creationTimestamp;

[.items[] | select(.metadata.labels["image-builder.io/ci"] != null)] as $runs
| ([$runs[] | select(branch != null)]
   | group_by([.metadata.namespace, branch])[]
   | (map(created) | max) as $newest
   | .[]
   | select((isDone | not) and (.spec.status == null) and created < $newest)
   | {verb: "cancel", namespace: .metadata.namespace, name: .metadata.name,
      say: "cancelled \(.metadata.namespace)/\(.metadata.name): a newer push to \(branch) replaces it"}),
  ([$runs[] | select(isDone)]
   | group_by(.metadata.namespace)[]
   | sort_by(created, .metadata.name) | reverse | .[keep:][]
   | {verb: "delete", namespace: .metadata.namespace, name: .metadata.name,
      say: "deleted \(.metadata.namespace)/\(.metadata.name), created \(created)"})
