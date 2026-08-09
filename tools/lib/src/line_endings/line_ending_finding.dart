import 'package:meta/meta.dart';

/// A disagreement between what .gitattributes fixes and what this tree holds.
///
/// Typed, so an assertion can say WHICH disagreement it expects instead of matching on prose, and
/// so a counter-probe can plant one shape and assert exactly that shape comes back.
@immutable
sealed class LineEndingFinding {
  const LineEndingFinding();

  /// What a person needs to read in order to act on this.
  String describe();

  @override
  String toString() => describe();
}

/// A path declared LF that carries a carriage return.
@immutable
final class CarriageReturnInAnLfPath extends LineEndingFinding {
  /// [path] is declared LF and carries a carriage return, first at [line].
  const CarriageReturnInAnLfPath({required this.path, required this.line});

  /// The path.
  final String path;

  /// The one-based line the first carriage return stands on.
  final int line;

  @override
  String describe() =>
      '$path is declared LF and carries a carriage return at line $line — this tree ships shell '
      'inside YAML block scalars, so a \\r here reaches a Tekton script block, reaches a pod, and '
      'comes back as "bad interpreter: /usr/bin/env bash^M"';
}

/// A text path whose line endings the declaration leaves to the machine.
@immutable
final class PathWithNoDeclaredEnding extends LineEndingFinding {
  /// Nothing in the declaration fixes the endings of [path].
  const PathWithNoDeclaredEnding(this.path);

  /// The path.
  final String path;

  @override
  String describe() =>
      '$path is text and .gitattributes fixes no ending for it, so what a checkout writes there is '
      'decided by that machine\'s core.eol and core.autocrlf — the same commit becomes two '
      'different files on two developers\' disks, and only one of them renders on a cluster';
}

/// A rule of the declaration that owns no tracked path.
@immutable
final class AttributeRuleOwnsNothing extends LineEndingFinding {
  /// [rule] owns nothing in this tree.
  const AttributeRuleOwnsNothing(this.rule);

  /// The rule, as the declaration writes it.
  final String rule;

  @override
  String describe() =>
      '.gitattributes: "$rule" owns no tracked path — a rule for a kind of file this repository '
      'does not carry is a rule nobody has read since the tree changed under it, and it tells the '
      'next reader that files exist here which do not';
}

/// The declaration selected nothing, so this audit decided nothing.
@immutable
final class NothingIsDeclared extends LineEndingFinding {
  /// No tracked path was owned by any rule.
  const NothingIsDeclared();

  @override
  String describe() =>
      '.gitattributes owns no tracked path at all, so nothing was judged — a check that measures '
      'nothing reads exactly like one that passed';
}
