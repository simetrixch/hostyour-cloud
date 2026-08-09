/// The pattern language branch-classes.yaml says its rules speak.
///
/// Bash pattern-match, where `*` matches `/` as well — so `charts/*` covers a whole subtree and
/// `*.sh` covers a script wherever it sits. That is not the same language as a shell glob or as a
/// package:glob pattern, both of which stop at a path separator, and the difference decides who
/// owns a path: under a stopping `*`, `charts/*` would own nothing at all and every rule in the
/// declaration would read as dead.
final class GlobPattern {
  /// The pattern written as [source].
  GlobPattern(this.source) : _expression = _compile(source);

  /// The pattern as the declaration writes it.
  final String source;

  final RegExp _expression;

  /// Whether [path] is one this pattern owns.
  bool matches(String path) => _expression.hasMatch(path);

  /// The paths of [candidates] this pattern owns, in the order they arrive.
  List<String> ownedIn(Iterable<String> candidates) =>
      candidates.where(matches).toList(growable: false);

  /// One concrete path this pattern would own, with every `*` standing for [word].
  ///
  /// What the books rules describe is not on the trunk — a registration and a foreign cluster map
  /// are written by the manager onto another branch — so an audit that only ever saw tracked paths
  /// could say nothing about them. This is how they are planted by name.
  String concreteWith(String word) => source.replaceAll('*', word);

  @override
  String toString() => source;

  static RegExp _compile(String pattern) {
    final StringBuffer expression = StringBuffer('^');
    for (final int unit in pattern.runes) {
      final String character = String.fromCharCode(unit);
      expression.write(switch (character) {
        '*' => '.*',
        '?' => '.',
        _ => RegExp.escape(character),
      });
    }
    expression.write(r'$');
    return RegExp(expression.toString());
  }
}
