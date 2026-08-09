import '../tree/source_tree.dart';
import 'dart_directive.dart';
import 'directive_case_finding.dart';

/// Every directive of this tree spells the path it names byte for byte.
///
/// `import 'Tree/source_tree.dart'` for a directory tracked as `tree/` resolves on Windows, which
/// is where this tree is edited, and does not resolve on a case-sensitive filesystem, which is
/// where it is cloned and deployed. Nothing else here catches it: the analyzer resolves an import
/// through the filesystem, and the Windows filesystem opens the wrong case without complaint.
///
/// THE COMPARISON IS AGAINST THE LISTING AND NEVER AGAINST WHETHER THE FILE OPENS. A check that
/// asked whether the resolved path can be opened would be green on this machine whatever case was
/// written, and would prove nothing at all. [SourceTree] carries the paths git tracks, each spelled
/// the way git records it, and git's spelling is the name a checkout writes on the other machine —
/// so every resolved target is held against that listing and the two are compared byte for byte.
///
/// WHAT IS JUDGED is every `import`, `export`, `part` and `part of` whose target is a path of this
/// tree: relative, or `package:` of a package this tree declares. A directive naming a path this
/// tree tracks under NO spelling is not a finding here — that one is broken on every platform, and
/// the analyzer already reports it.
final class DirectiveCaseAudit {
  /// The audit of [tree].
  const DirectiveCaseAudit(this.tree);

  /// The tree being decided about.
  final SourceTree tree;

  /// Every directive this audit decided about.
  ///
  /// This is the denominator: a run in which it is empty judged nothing, and the caller reads it so
  /// that an empty list of findings cannot be mistaken for agreement.
  List<DartDirective> get judged {
    final Map<String, String> listing = _byLowerCase();
    return <DartDirective>[
      for (final DartDirective directive in directivesIn(tree))
        if (listing.containsKey(directive.target.toLowerCase())) directive,
    ];
  }

  /// Every directive whose spelling differs from the tracked one.
  List<DirectiveCaseFinding> findings() {
    final Map<String, String> listing = _byLowerCase();
    return <DirectiveCaseFinding>[
      for (final DartDirective directive in directivesIn(tree))
        if (!tree.holds(directive.target))
          if (listing[directive.target.toLowerCase()] case final String tracked)
            DirectiveCaseFinding(directive: directive, tracked: tracked),
    ];
  }

  /// The paths of the tree, keyed by their lower-cased selves.
  ///
  /// Lower-casing both sides is what makes "the same file under another spelling" one lookup, and
  /// the value keeps the spelling the listing carries, which is what a finding names as the fix.
  Map<String, String> _byLowerCase() => <String, String>{
    for (final String path in tree.paths) path.toLowerCase(): path,
  };
}
