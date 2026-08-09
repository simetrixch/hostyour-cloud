import 'package:meta/meta.dart';

import '../installation.dart';
import 'branch_class.dart';
import 'derived_licence.dart';

/// A disagreement between what branch-classes.yaml declares and what is true of this tree.
///
/// Typed, so an assertion can say WHICH disagreement it expects instead of matching on prose, and
/// so a counter-probe can plant one shape and assert exactly that shape comes back.
@immutable
sealed class BranchClassFinding {
  const BranchClassFinding();

  /// What a person needs to read in order to act on this.
  String describe();

  @override
  String toString() => describe();
}

/// A tracked path no rule owns.
@immutable
final class PathWithoutAClass extends BranchClassFinding {
  /// [path] is tracked and unowned.
  const PathWithoutAClass(this.path);

  /// The path.
  final String path;

  @override
  String describe() =>
      '$path is tracked and no rule in classes: owns it, so nothing says what it is — and a path '
      'needs its class BEFORE it is committed, or the first commit of it is the unclassified one';
}

/// A rule that owns nothing and nothing says why.
@immutable
final class RuleOwnsNothing extends BranchClassFinding {
  /// The rule [pattern] of section [section] owns no path.
  const RuleOwnsNothing({required this.section, required this.pattern});

  /// Which section it stands in.
  final String section;

  /// The pattern.
  final String pattern;

  @override
  String describe() =>
      '$section: "$pattern" owns no tracked path and trunk-absent: does not say why — a rule '
      'placed BELOW the glob it is an exception to looks exactly like this, because the first '
      'match owns the path and later rules never see it';
}

/// A word in a section that names none of the values that section allows.
@immutable
final class UnreadableWord extends BranchClassFinding {
  /// [section] carries [word] for [pattern], and it names nothing.
  const UnreadableWord({required this.section, required this.pattern, required this.word});

  /// Which section.
  final String section;

  /// Which rule.
  final String pattern;

  /// What it says.
  final String word;

  @override
  String describe() =>
      '$section: "$pattern" says "$word", which is not one of the values that section allows — a '
      'fourth class introduced by a typo is a rule nothing can act on';
}

/// A path classified mixed.
@immutable
final class PathIsMixed extends BranchClassFinding {
  /// [pattern] is mixed, and [hasUncertainRow] says whether uncertain: carries a row for it.
  const PathIsMixed({required this.pattern, required this.hasUncertainRow});

  /// The rule.
  final String pattern;

  /// Whether the second class and what would settle it are written down.
  final bool hasUncertainRow;

  @override
  String describe() =>
      'classes: "$pattern" is mixed — it carries values of two classes at once and no class is true '
      'of the whole of it, which the declaration calls a defect rather than a state to keep'
      '${hasUncertainRow ? '' : ', and uncertain: carries no row saying what the second class is '
                'or what would settle it'}';
}

/// A rule that stands on another branch and owns a path here after all.
@immutable
final class TrunkCarriesAnAbsentRule extends BranchClassFinding {
  /// [pattern] is declared trunk-absent and owns [paths] here.
  const TrunkCarriesAnAbsentRule({required this.pattern, required this.paths});

  /// The rule.
  final String pattern;

  /// What it owns on the trunk.
  final List<String> paths;

  @override
  String describe() =>
      'trunk-absent: "$pattern" stands on an install or a books branch, and the trunk carries '
      '${paths.length} path(s) matching it: ${paths.join(', ')}';
}

/// A trunk-absent rule whose class disagrees with the branch it names.
@immutable
final class TrunkAbsentClassDisagrees extends BranchClassFinding {
  /// [pattern] names a branch that fixes [expected] and classes: says [declared].
  const TrunkAbsentClassDisagrees({
    required this.pattern,
    required this.expected,
    required this.declared,
  });

  /// The rule.
  final String pattern;

  /// What the side it names requires.
  final BranchClass expected;

  /// What classes: says, or null when classes: carries no rule of that name.
  final BranchClass? declared;

  @override
  String describe() => switch (declared) {
    null => 'trunk-absent: "$pattern" fixes a class and classes: carries no rule of that name',
    final BranchClass got =>
      'trunk-absent: "$pattern" names a branch whose class is ${expected.word} and classes: says '
          '${got.word}',
  };
}

/// A rule held outside git that owns a tracked path.
@immutable
final class OutsideRuleIsTracked extends BranchClassFinding {
  /// [pattern] is held outside git and [path] is tracked.
  const OutsideRuleIsTracked({required this.pattern, required this.path});

  /// The rule.
  final String pattern;

  /// The tracked path it owns.
  final String path;

  @override
  String describe() =>
      'outside: "$pattern" is held deliberately outside git and $path is tracked — a declaration '
      'that promises every tracked path its class has to say what it does NOT cover';
}

/// A path the domain stamp would rewrite that stamped: does not declare.
@immutable
final class StampReachesAnUndeclaredPath extends BranchClassFinding {
  /// The stamp reaches [path].
  const StampReachesAnUndeclaredPath(this.path);

  /// The path.
  final String path;

  @override
  String describe() =>
      'the domain stamp would rewrite $path and stamped: does not declare it — installation state '
      'nobody wrote down, and on the next install branch it becomes that installation\'s domain';
}

/// A path stamped: declares that the domain stamp does not reach.
@immutable
final class StampMissesADeclaredPath extends BranchClassFinding {
  /// [path] is declared stamped and is not reached.
  const StampMissesADeclaredPath(this.path);

  /// The path.
  final String path;

  @override
  String describe() =>
      'stamped: declares $path is rewritten and the domain stamp does not reach it — either the '
      'placeholder left the file or an exclusion grew over it, and the branch would carry the '
      'trunk\'s value where it needs its own';
}

/// A stamped path whose class says it is not installation state.
@immutable
final class StampedPathIsNotInstallationState extends BranchClassFinding {
  /// [path] is stamped and its owning rule says [declared].
  const StampedPathIsNotInstallationState({
    required this.path,
    required this.rule,
    required this.declared,
  });

  /// The path.
  final String path;

  /// The rule that owns it, or null when none does.
  final String? rule;

  /// What that rule says, or null when there is none.
  final BranchClass? declared;

  @override
  String describe() => switch ((rule, declared)) {
    (final String owner, final BranchClass says) =>
      'stamped: "$path" is installation state on a branch and classes: "$owner" calls it '
          '${says.word} — a product path is byte-identical in every installation and a books path '
          'is not on the trunk at all',
    _ => 'stamped: "$path" is declared and no rule in classes: owns it',
  };
}

/// A path a never-stamp rule owns that the domain stamp reaches once the placeholder is in it.
@immutable
final class NeverStampPathIsReachable extends BranchClassFinding {
  /// [path], owned by never-stamp rule [pattern], is inside the stamp's reach.
  const NeverStampPathIsReachable({required this.pattern, required this.path});

  /// The rule.
  final String pattern;

  /// The path it owns.
  final String path;

  @override
  String describe() =>
      'never-stamp: "$pattern" owns $path, whose placeholder is a guard, a fixture, an '
      'illustration or the documentation of the stamp itself — and the domain stamp reaches it, so '
      'an installation would rewrite it to a real domain';
}

/// The never-stamp section planted nothing, so that half decided nothing.
@immutable
final class NeverStampPlantedNothing extends BranchClassFinding {
  /// No tracked path matched any never-stamp rule.
  const NeverStampPlantedNothing();

  @override
  String describe() =>
      'never-stamp: no tracked path matched any of its rules, so nothing was planted and that half '
      'of this audit decided nothing — a check that measures nothing reads exactly like one that '
      'passed';
}

/// A path the role stamp removes that no derived rule owns.
@immutable
final class PrunedPathIsNotDerived extends BranchClassFinding {
  /// [path] is removed on a [role] at [stage] under [licence] and no rule grants it.
  const PrunedPathIsNotDerived({
    required this.path,
    required this.stage,
    required this.role,
    required this.licence,
  });

  /// The path.
  final String path;

  /// The stage of the branch it is removed from.
  final String stage;

  /// The role of that branch.
  final ClusterRole role;

  /// The axis the removal came from.
  final DerivedLicence licence;

  @override
  String describe() =>
      'the role stamp removes $path from a ${role.name} at stage $stage as "${licence.word}" and '
      'derived: declares no rule for it — a merge conflict there would stop a sync that nothing '
      'needed stopped';
}

/// A derived rule whose licence is not the axis the role stamp really prunes on.
@immutable
final class DerivedLicenceDisagrees extends BranchClassFinding {
  /// [pattern] grants [granted] and the stamp prunes [example] as [actual].
  const DerivedLicenceDisagrees({
    required this.pattern,
    required this.granted,
    required this.actual,
    required this.example,
  });

  /// The rule.
  final String pattern;

  /// What it grants.
  final DerivedLicence granted;

  /// What the stamp does.
  final DerivedLicence actual;

  /// One path it holds for.
  final String example;

  @override
  String describe() =>
      'derived: "$pattern" grants "${granted.word}" and the role stamp prunes what it owns as '
      '"${actual.word}" — $example is one';
}

/// A derived rule granting `always` over a path no stamper regenerates.
@immutable
final class AlwaysWithoutAWriter extends BranchClassFinding {
  /// [pattern] grants `always` and [path] is regenerated by nothing.
  const AlwaysWithoutAWriter({required this.pattern, required this.path});

  /// The rule.
  final String pattern;

  /// One path it owns that nothing rewrites.
  final String path;

  @override
  String describe() =>
      'derived: "$pattern" grants "always", and $path is regenerated by no stamper — "always" is a '
      'licence to resolve a conflict there toward the pin on the grounds that a stamper rewrites '
      'it a moment later, and nothing does, so the resolution would throw away what only the '
      'branch had';
}

/// A path a stamper writes again on every run that no derived rule grants `always` over.
///
/// The other direction of [AlwaysWithoutAWriter], and the cheaper of the two: a conflict here stops
/// a sync that the next run would have settled by rewriting the file. It is reported because a
/// licence nobody restates when a stamper arrives is a licence nobody withdraws when one leaves —
/// which is how two rows came to rest on a program that existed nowhere.
@immutable
final class RegeneratedPathIsNotDerived extends BranchClassFinding {
  /// A stamper writes [path] again and derived: grants no `always` over it.
  const RegeneratedPathIsNotDerived(this.path);

  /// The path.
  final String path;

  @override
  String describe() =>
      'a stamper writes $path again on every run and derived: grants no "always" over it — a merge '
      'conflict there would stop a sync that the next run would have settled by rewriting the file';
}
