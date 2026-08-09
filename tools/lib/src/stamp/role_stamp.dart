import 'package:meta/meta.dart';

import '../branch/derived_licence.dart';
import '../installation.dart';

/// What an install branch does NOT carry, mirrored so a declaration can be measured against it.
///
/// The trunk is generic in two directions at once: it carries all three stages, because it is the
/// tree every installation is cut from, and it carries the books, because it does not know which
/// cluster will read them. An installation is neither — exactly one stage, exactly one role — and
/// the step that reduces it is `StampRole`, Dart, in simetrixch/ansiwise-plugins under
/// `hostyour-cloud/lib/src/steps/branch/stamp_role.dart`.
///
/// REMOVING THE OTHER TWO STAGES IS NOT TIDYING. It is what makes it impossible for the stage a
/// chart renders, the paths its secrets are read from and the names of its releases to disagree
/// with one another: there is no second stage left for anything to resolve to by accident.
///
/// THE ROLE IS NEVER GUESSED, and the branch's own map is kept by name. A slave's branch is pruned
/// of every registration and of every foreign cluster map; its own map is what the pruning was
/// decided from, so it survives, and that one exception is the whole of the difference between
/// [DerivedLicence.booksBranchOnly] and [DerivedLicence.foreignMapOnly].
final class RoleStamp {
  /// The stamp applied to a branch of [stage] holding [role], whose own map is [ownMap].
  const RoleStamp({required this.stage, required this.role, required this.ownMap});

  /// Which stage the branch keeps.
  final String stage;

  /// What the cluster is.
  final ClusterRole role;

  /// Where the branch's own cluster map stands, relative to the top of the checkout.
  final String ownMap;

  /// Whether this stamp removes [path], and under which licence.
  PruneVerdict verdictOn(String path) {
    for (final String other in stages) {
      if (other == stage) {
        continue;
      }
      // `StampRole._stagePatterns`, anchored at the top of the checkout so that the product
      // material a chart keeps under its own templates/ is never one of them.
      if (path == 'platform/values-$other.yaml' ||
          path.startsWith('argocd/$other/') ||
          _appStageValues(path, other)) {
        return const Pruned(DerivedLicence.otherStages);
      }
    }
    if (role == ClusterRole.slave) {
      if (path.startsWith('registrations/')) {
        return const Pruned(DerivedLicence.booksBranchOnly);
      }
      if (_clusterMap.hasMatch(path) && path != ownMap) {
        return const Pruned(DerivedLicence.foreignMapOnly);
      }
    }
    return const Kept();
  }

  /// `apps/[^/]+/values-<other>.yaml` — one level under apps/ and no deeper.
  static bool _appStageValues(String path, String other) {
    if (!path.startsWith('apps/') || !path.endsWith('/values-$other.yaml')) {
      return false;
    }
    return path.split('/').length == 3;
  }

  static final RegExp _clusterMap = RegExp(r'^clusters/active/[^/]+\.yaml$');
}

/// What the role stamp does with a path.
///
/// Sealed rather than a nullable licence: "kept" is an answer this audit acts on, and code that has
/// to name which answer it is holding cannot read a missing value as "not pruned" by accident.
@immutable
sealed class PruneVerdict {
  const PruneVerdict();
}

/// The path is removed, under [licence].
@immutable
final class Pruned extends PruneVerdict {
  /// A removal under [licence].
  const Pruned(this.licence);

  /// The axis the removal came from, which is the word a `derived:` rule must carry for it.
  final DerivedLicence licence;
}

/// The path stays, and the branch owns whatever is in it.
@immutable
final class Kept extends PruneVerdict {
  /// A path this stamp leaves alone.
  const Kept();
}
