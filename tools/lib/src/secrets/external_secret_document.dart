import '../tree/source_tree.dart';
import 'refresh_field.dart';

/// One document of `kind: ExternalSecret`, as it stands in this tree.
///
/// WHAT IS READ IS THE TEMPLATE AND NOT THE RENDER, and that is the whole point of reading it here.
/// The rule these documents carry is that two lines of the spec are LITERALS; a rendered manifest
/// has already resolved `{{ .Values.… }}` into whatever one values file happened to say, so a render
/// answers what one installation got rather than what every installation is fixed to.
///
/// A DOCUMENT IS WHAT `---` SEPARATES at column 0, the way YAML separates one and the way a chart
/// emits one per resource. An indented `---` is content of a block scalar and separates nothing, so
/// a shell script shipped inside a Tekton `script:` block cannot cut a document in half.
///
/// THE KIND IS READ AT COLUMN 0 ONLY. `kind: ExternalSecret` also stands indented in
/// apps/external-secrets/templates/crd-externalsecret.yaml, where it is the CustomResourceDefinition
/// naming the kind it defines rather than an instance of it — and that same file states
/// `refreshPolicy` and `refreshInterval` as schema properties with the upstream defaults behind
/// them. A scan that took every line would judge the definition of the resource by the rule its
/// instances carry, and report the vendored CRD as a violation of it.
final class ExternalSecretDocument {
  /// The document in [path] whose `kind:` line is [kindLine], holding [lines] and beginning at
  /// [firstLine]. Line numbers are one-based, so they are the numbers an editor shows.
  const ExternalSecretDocument({
    required this.path,
    required this.kindLine,
    required this.firstLine,
    required this.lines,
  });

  /// The path the document stands in.
  final String path;

  /// The one-based line its `kind: ExternalSecret` stands on.
  final int kindLine;

  /// The one-based line the document begins on.
  final int firstLine;

  /// Its lines, in the order they stand, the separators that bound it excluded.
  final List<String> lines;

  /// Every document of the kind in the chart material of [tree], in path order and in the order they
  /// stand in a file.
  static List<ExternalSecretDocument> allIn(SourceTree tree) {
    final List<ExternalSecretDocument> found = <ExternalSecretDocument>[];
    for (final String path in tree.chartMaterial) {
      final String? text = tree.textOf(path);
      if (text == null) {
        continue;
      }
      final List<String> lines = SourceTree.linesOf(text);
      int begins = 0;
      for (int at = 0; at <= lines.length; at++) {
        if (at < lines.length && lines[at].trimRight() != _separator) {
          continue;
        }
        final ExternalSecretDocument? document = _readFrom(
          path,
          lines.sublist(begins, at),
          begins + 1,
        );
        if (document != null) {
          found.add(document);
        }
        begins = at + 1;
      }
    }
    return found;
  }

  /// Where [field] is stated in this document and what it carries, or null when nothing states it.
  ///
  /// The first statement wins, because that is the one a YAML reader keeps.
  ({int line, String value})? statementOf(RefreshField field) {
    for (int at = 0; at < lines.length; at++) {
      final Match? stated = field.statement.firstMatch(lines[at]);
      if (stated != null) {
        return (line: firstLine + at, value: (stated.group(1) ?? '').trim());
      }
    }
    return null;
  }

  static ExternalSecretDocument? _readFrom(String path, List<String> lines, int firstLine) {
    for (int at = 0; at < lines.length; at++) {
      if (_kind.hasMatch(lines[at])) {
        return ExternalSecretDocument(
          path: path,
          kindLine: firstLine + at,
          firstLine: firstLine,
          lines: lines,
        );
      }
    }
    return null;
  }

  static const String _separator = '---';

  static final RegExp _kind = RegExp(r'^kind:[ \t]*ExternalSecret[ \t]*(#.*)?$');
}
