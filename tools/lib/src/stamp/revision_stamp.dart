/// Which manifests a branch run writes again, mirrored so a declaration can be measured against it.
///
/// Everything under `argocd/` names the branch it reads from. On the trunk that is the trunk
/// itself, which is what makes the trunk a product tree rather than an installation; on a branch it
/// is that installation's own name. The step that retargets it is `StampRevision`, Dart, in
/// simetrixch/ansiwise-plugins under `hostyour-cloud/lib/src/steps/branch/stamp_revision.dart`.
///
/// WHAT EARNS THE LICENCE HERE IS THE UNDO AND NOT THE APPLY. The step's `apply` rewrites only the
/// lines that still name the trunk, so on its own it would leave anything else a branch had put
/// there. Its `undo` is `git checkout -- argocd`, which restores the whole directory, and
/// `StampRole` removes the two stage trees this installation is not. Between them, nothing a branch
/// holds under this directory survives a run that the trunk does not also hold.
///
/// THIS IS A MIRROR AND IT CAN DRIFT. The step is in another repository and this one cannot run it,
/// so the one constant it turns on is restated here with the field it came from, and the
/// branch-class audit drives the mirror over planted paths.
final class RevisionStamp {
  /// The stamp as the step defines it.
  const RevisionStamp();

  /// `StampRevision.tree` — the directory holding the manifests that name a branch.
  ///
  /// Layout of the tree being generated rather than a value of one installation: every installation
  /// keeps its generators in the same place.
  static const String tree = 'argocd';

  /// Whether a run writes [path] again, whatever the stage and whatever the role.
  bool regenerates(String path) => path == tree || path.startsWith('$tree/');
}
