import '../tree/source_tree.dart';
import 'attribute_declaration.dart';
import 'line_ending_finding.dart';

/// .gitattributes fixes the bytes of every path here, and this is what reads it back.
///
/// WHAT IS AT STAKE IS NOT A CHECKED-OUT SCRIPT. This repository is Helm charts and ArgoCD
/// manifests and carries no shell at all, so there is no file a kernel opens and no shebang it
/// could misread — the reason a sibling repository deleted its line-ending check outright. Here the
/// shebang sits one level down: six chart templates ship a script inside a YAML block scalar, which
/// a cluster writes to disk and a pod executes. `apps/image-builder/templates/tasks/git-clone.yaml`
/// and five like it hold `#!/usr/bin/env sh` as the first line of a Tekton `script:`. A carriage
/// return in one of those YAML files travels the whole way and arrives as `bad interpreter:
/// /usr/bin/env bash^M`, which is the failure .gitattributes names in its own header, delivered by
/// a cluster instead of by a checkout.
///
/// THE WORKING COPY IS WHAT IS MEASURED, and it is the broader of the two things it could be. With
/// `* text=auto eol=lf` git stores LF in the index the moment a file is added, and reports the
/// working copy as `w/crlf` until it next touches the file — so a CRLF file is a state that really
/// exists here, that helm renders from during this gate, and that becomes permanent the moment the
/// declaration stops covering it. A file whose index copy is CRLF is checked out as CRLF too, so
/// measuring the working copy catches that as well.
///
/// IT DECIDES IN THREE DIRECTIONS. A path declared LF that carries a carriage return; a text path
/// nothing declares, whose bytes are then decided by the developer's own git config; and a rule of
/// the declaration that owns nothing, which is the standard branch-classes.yaml already holds
/// itself to and the reason a declaration cannot go on describing a repository that has changed
/// underneath it.
final class LineEndingAudit {
  /// The audit of [tree] against [declaration].
  const LineEndingAudit({required this.tree, required this.declaration});

  /// The tree being decided about.
  final SourceTree tree;

  /// What it declares about itself.
  final AttributeDeclaration declaration;

  /// Everything the declaration fixes that is not true of this tree.
  List<LineEndingFinding> findings() => <LineEndingFinding>[
    ...carriageReturnsInLfPaths(),
    ...pathsWithNoDeclaredEnding(),
    ...rulesThatOwnNothing(),
  ];

  /// Paths declared LF that carry a carriage return.
  ///
  /// Any carriage return and not only a CRLF pair: LF means there is no `\r` in the file, and a
  /// lone one delivered into a script is the same broken byte with one fewer neighbour.
  List<LineEndingFinding> carriageReturnsInLfPaths() {
    final List<LineEndingFinding> found = <LineEndingFinding>[];
    for (final String path in tree.paths) {
      final String? text = tree.textOf(path);
      if (text == null || declaration.endingOf(path) != DeclaredEnding.lf) {
        continue;
      }
      final int at = text.indexOf('\r');
      if (at < 0) {
        continue;
      }
      found.add(
        CarriageReturnInAnLfPath(
          path: path,
          line: '\n'.allMatches(text.substring(0, at)).length + 1,
        ),
      );
    }
    return found;
  }

  /// Text paths whose endings the declaration leaves to the machine.
  ///
  /// Only what is really text: a path whose bytes hold a zero is one this tree cannot read and one
  /// git's own content detection keeps its hands off, so nothing is decided about it either way.
  List<LineEndingFinding> pathsWithNoDeclaredEnding() => <LineEndingFinding>[
    for (final String path in tree.paths)
      if (tree.textOf(path) != null && declaration.endingOf(path) == DeclaredEnding.undeclared)
        PathWithNoDeclaredEnding(path),
  ];

  /// Rules that own no tracked path, and the case where none of them owns anything.
  List<LineEndingFinding> rulesThatOwnNothing() {
    final List<AttributeRule> idle = declaration.rulesOwningNone(tree.paths);
    if (declaration.rules.isNotEmpty && idle.length == declaration.rules.length) {
      return const <LineEndingFinding>[NothingIsDeclared()];
    }
    return <LineEndingFinding>[
      for (final AttributeRule rule in idle) AttributeRuleOwnsNothing(rule.toString()),
    ];
  }
}
