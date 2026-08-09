import '../installation.dart';
import '../tree/source_tree.dart';

/// Where an installation's own domain is written into the tree, mirrored so it can be measured.
///
/// Generating an installation means replacing the placeholder with that installation's fqdn in
/// every file where the placeholder IS installation state — and in none of the files where it is a
/// guard, a fixture, an illustration or the documentation of the stamp itself. The step that does
/// it is `StampFqdn`, Dart, in simetrixch/ansiwise-plugins under
/// `hostyour-cloud/lib/src/steps/branch/stamp_fqdn.dart`.
///
/// THIS IS A MIRROR AND IT CAN DRIFT. The step is in another repository and this one cannot run
/// it, so its selection rule is restated here with the field each constant came from, and the
/// branch-class audit drives the mirror over planted paths to prove every exclusion still holds.
/// The alternative is what this repository already had: a declaration nobody measured at all.
///
/// TWO OF THE EXCLUSIONS ARE PAID FOR. Scripts are excluded as a class because the placeholder
/// inside one is never installation state: before the exclusion existed, a script whose own guard
/// compared against the placeholder came out refusing the very domain it was being installed for,
/// and a library whose empty-value test read the placeholder came out producing hosts with no
/// domain at all. And a script is recognised by its first line as well as by its suffix, because a
/// suffix list alone let an extensionless script through and the stamp reached into one again.
final class DomainStamp {
  /// The stamp as the step defines it.
  const DomainStamp();

  /// `StampFqdn.placeholder` — what the trunk says where an installation says its own name.
  static const String placeholder = placeholderDomain;

  /// `StampFqdn.excludedSegments` — a path segment whose contents are product material.
  ///
  /// A SEGMENT and not a prefix: a chart's own `templates/` sits several levels down and is the
  /// same kind of thing as the one at the top of the tree.
  static const List<String> excludedSegments = <String>['docs', 'templates'];

  /// `StampFqdn.excludedName` — the file excluded because it is the declaration of this stamp.
  ///
  /// It states which paths hold installation state, so it quotes the placeholder in order to
  /// explain what is done to it. Rewritten, the one file an operator opens to learn which paths
  /// must never be stamped would itself name a real domain.
  static const String excludedName = 'branch-classes.yaml';

  /// `StampFqdn.scriptSuffixes` — the scripts that carry no first line to recognise them by.
  static const List<String> scriptSuffixes = <String>['.sh', '.ps1'];

  /// The paths of [tree] this stamp would rewrite, sorted.
  ///
  /// Takes a tree rather than reaching for the repository, so a counter-probe can drive the same
  /// selection over paths it planted — including the ones the exclusions must hold for, which no
  /// real tree is obliged to carry.
  List<String> selectionIn(SourceTree tree) {
    final List<String> selected = <String>[
      for (final String path in tree.paths)
        if (_selects(path, tree.textOf(path))) path,
    ];
    return selected;
  }

  /// Whether this stamp would rewrite [path], whose content is [text].
  bool selects(String path, String? text) => _selects(path, text);

  bool _selects(String path, String? text) {
    if (text == null || !text.contains(placeholder)) {
      return false;
    }
    final List<String> segments = path.split('/');
    if (segments.any(excludedSegments.contains)) {
      return false;
    }
    if (segments.last == excludedName) {
      return false;
    }
    if (scriptSuffixes.any(path.endsWith)) {
      return false;
    }
    if (text.startsWith('#!')) {
      return false;
    }
    return true;
  }
}
