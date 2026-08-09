/// Which application toggles a branch run decides, mirrored so a declaration can be measured
/// against it.
///
/// Every application of this platform has a toggle under `cluster/apps/<name>.yaml` carrying one
/// line, `deploy:`, and the ApplicationSet renders an Application only where it says `"true"`. On
/// the trunk they carry a generic default, because the trunk is not a cluster and cannot know. The
/// step that rewrites them is `StampAppToggles`, Dart, in simetrixch/ansiwise-plugins under
/// `hostyour-cloud/lib/src/steps/branch/stamp_app_toggles.dart`.
///
/// NINE OF THEM, AND NOT THE WHOLE DIRECTORY. Three sets are decided by what this cluster IS — what
/// runs beside the registry, what the master part provides once per installation, and the one
/// agent that runs exactly where the master part is not. Every other toggle keeps whatever the
/// trunk says, because those are an operator's decisions on the branch — whether this installation
/// wants a database browser, a mail relay — and a step that overwrote them would undo a choice
/// somebody made, silently, on the next run.
///
/// That distinction is the whole reason this mirror exists rather than a glob. A licence to resolve
/// a merge conflict under `cluster/apps/` toward the pin is safe for the nine, because a run writes
/// the deploy line again a moment later and the deploy line is the only thing a branch holds in
/// those files that the trunk does not. Over the rest it would throw away the only statement that
/// an operator ever made.
///
/// THIS IS A MIRROR AND IT CAN DRIFT. The step is in another repository and this one cannot run it,
/// so its three sets are restated here with the field each came from, and the branch-class audit
/// drives the mirror over planted paths and against the toggles this tree really carries.
final class AppToggleStamp {
  /// The stamp as the step defines it.
  const AppToggleStamp();

  /// `StampAppToggles.onTheBuildPlane` — the applications that run on the build plane and nowhere
  /// else.
  ///
  /// tekton, the registry and image-builder are the plane itself; consumer-build is one build
  /// namespace per registered unit, which only means anything where the registry and the
  /// EventListener are; gate-runner references image-builder's shared clone Task; and the manager
  /// is deployed beside the registry it pushes to.
  static const List<String> onTheBuildPlane = <String>[
    'consumer-build',
    'gate-runner',
    'image-builder',
    'manager',
    'registry',
    'tekton',
  ];

  /// `StampAppToggles.whereTheMasterIs` — the applications provided once per installation, by the
  /// cluster holding the master part.
  static const List<String> whereTheMasterIs = <String>['tailnet-coordinator', 'observability'];

  /// `StampAppToggles.whereTheMasterIsNot` — the applications that run exactly where the master part
  /// is not.
  ///
  /// One entry, and it is the mirror of `observability` above: a cluster without the master part
  /// runs the light push agent instead of the full stack, and running both would have it scraping
  /// itself and shipping the result to itself.
  static const List<String> whereTheMasterIsNot = <String>['observability-agent'];

  /// Every application whose toggle a run decides.
  static const List<String> decided = <String>[
    ...onTheBuildPlane,
    ...whereTheMasterIs,
    ...whereTheMasterIsNot,
  ];

  /// `StampAppToggles.pathOf` — where the toggle of [app] lives, relative to the top of the
  /// checkout.
  static String pathOf(String app) => 'cluster/apps/$app.yaml';

  /// Whether a run writes [path] again, whatever the stage and whatever the role.
  bool regenerates(String path) => decided.any((String app) => pathOf(app) == path);
}
