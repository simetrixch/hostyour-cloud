import 'package:meta/meta.dart';

/// What .gitattributes says the bytes of every path of this tree must be.
///
/// LAST MATCH WINS, which is the opposite of branch-classes.yaml. git applies every line that owns
/// a path, in order, and each one overrides what the lines above it set — so the generic
/// `* text=auto eol=lf` at the top is refined by everything below it rather than swallowing it. A
/// reader that stopped at the first match would answer "text" for an image and report every binary
/// in the tree as a defect.
///
/// A PATTERN WITHOUT A SLASH IS MATCHED AGAINST THE FILE NAME, and one with a slash against the
/// whole path, which is git's own rule for these files and for .gitignore. `*.yaml` therefore owns
/// a chart template several levels down, and that is how the one rule that matters here reaches the
/// files that matter.
///
/// TWO WILDCARDS AND NO MORE. `*` and `?` stop at a path separator, as git's do. A character class
/// or a `**` would compile to something narrower than git means, and the rule would then own fewer
/// paths than git gives it — which this audit reports, because a rule that owns nothing is a
/// finding.
@immutable
final class AttributeDeclaration {
  const AttributeDeclaration._(this.rules);

  /// The declaration written as [text].
  ///
  /// A line whose first character is `#` is a comment and a line with no attributes after its
  /// pattern states nothing, so neither becomes a rule that could then own paths and decide about
  /// them.
  factory AttributeDeclaration.parse(String text) {
    final List<AttributeRule> rules = <AttributeRule>[];
    for (final String line in text.split('\n')) {
      final String trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }
      final List<String> words = trimmed.split(RegExp(r'\s+'));
      if (words.length < 2) {
        continue;
      }
      rules.add(
        AttributeRule(pattern: words.first, attributes: words.skip(1).toList(growable: false)),
      );
    }
    return AttributeDeclaration._(List<AttributeRule>.unmodifiable(rules));
  }

  /// Where the declaration stands, relative to the top of the repository.
  static const String file = '.gitattributes';

  /// Every rule the file carries, in document order.
  final List<AttributeRule> rules;

  /// What the declaration fixes for [path].
  DeclaredEnding endingOf(String path) {
    bool? isText;
    DeclaredEnding? ending;
    for (final AttributeRule rule in rules) {
      if (!rule.owns(path)) {
        continue;
      }
      for (final String attribute in rule.attributes) {
        switch (attribute) {
          case 'binary' || '-text':
            isText = false;
          case 'text' || 'text=auto':
            isText ??= true;
          case 'eol=lf':
            // git ignores an eol on a path it was told is not text, so the order of these two is
            // the order the declaration wrote them in and not a preference of this reader.
            isText ??= true;
            ending = DeclaredEnding.lf;
          case 'eol=crlf':
            isText ??= true;
            ending = DeclaredEnding.crlf;
        }
      }
    }
    if (isText == false) {
      return DeclaredEnding.binary;
    }
    if (isText == null) {
      return DeclaredEnding.undeclared;
    }
    return ending ?? DeclaredEnding.undeclared;
  }

  /// The rules that own none of [paths], in document order.
  List<AttributeRule> rulesOwningNone(Iterable<String> paths) => <AttributeRule>[
    for (final AttributeRule rule in rules)
      if (!paths.any(rule.owns)) rule,
  ];
}

/// One line of .gitattributes: a pattern and what it says about what the pattern owns.
@immutable
final class AttributeRule {
  /// The rule written as [pattern] with [attributes].
  AttributeRule({required this.pattern, required this.attributes})
    : _expression = _compile(pattern),
      _againstTheNameOnly = !pattern.contains('/');

  /// The pattern as the declaration writes it.
  final String pattern;

  /// What it says, as the words git reads them.
  final List<String> attributes;

  final RegExp _expression;
  final bool _againstTheNameOnly;

  /// Whether [path] is one this rule owns.
  bool owns(String path) => _expression.hasMatch(_againstTheNameOnly ? path.split('/').last : path);

  @override
  String toString() => '$pattern ${attributes.join(' ')}';

  static RegExp _compile(String pattern) {
    final StringBuffer expression = StringBuffer('^');
    for (final int unit in pattern.runes) {
      final String character = String.fromCharCode(unit);
      expression.write(switch (character) {
        '*' => '[^/]*',
        '?' => '[^/]',
        _ => RegExp.escape(character),
      });
    }
    expression.write(r'$');
    return RegExp(expression.toString());
  }
}

/// What .gitattributes fixes for a path.
///
/// An enum and never a String, for the same reason a branch class is one: a word the declaration
/// carries that names none of these is a rule nothing can act on.
enum DeclaredEnding {
  /// LF in the index and LF in the working copy, on every platform.
  lf,

  /// CRLF in the working copy on purpose.
  crlf,

  /// Bytes nobody converts — `binary`, or `-text`.
  binary,

  /// Nothing is fixed: either no rule owns the path, or the rule that does calls it text without
  /// saying which ending. What a checkout then writes is decided by the machine's own core.eol and
  /// core.autocrlf, so the same commit becomes two different files on two developers' disks.
  undeclared,
}
