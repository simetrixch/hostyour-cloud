import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../tree/source_tree.dart';

/// One `import`, `export`, `part` or `part of` of a Dart file, resolved to the path it names.
///
/// The URI is kept beside the path it resolves to, because those are the two halves a person needs
/// to act: the URI is what stands in the file and gets edited, and the path is what the tree is
/// searched for.
@immutable
final class DartDirective {
  /// The directive on [line] of [file], written as [uri], naming [target].
  const DartDirective({
    required this.file,
    required this.line,
    required this.uri,
    required this.target,
  });

  /// Where the directive stands, relative to the repository root.
  final String file;

  /// The one-based line it stands on.
  final int line;

  /// The URI as the directive spells it.
  final String uri;

  /// The tree-relative path that URI resolves to, carrying the directive's own spelling.
  final String target;

  /// How it is written in a finding.
  String get coordinate => '$file:$line';
}

/// Every directive of every Dart file of [tree] that resolves to a path of [tree] — under the
/// spelling the directive uses, or under another one.
///
/// A directive naming something outside the tree is left out here rather than reported empty-handed
/// later: `dart:` names no file at all, and a package this tree does not declare resolves through
/// the pub cache, whose spelling is pub's and not this repository's.
List<DartDirective> directivesIn(SourceTree tree) {
  final Map<String, String> packages = packageDirectoriesIn(tree);
  final List<DartDirective> found = <DartDirective>[];
  for (final String path in tree.paths) {
    if (!path.endsWith('.dart')) {
      continue;
    }
    final String? text = tree.textOf(path);
    if (text == null) {
      continue;
    }
    final List<String> lines = SourceTree.linesOf(text);
    for (int i = 0; i < lines.length; i++) {
      final String? uri = _directiveLine.firstMatch(lines[i])?.group(2);
      if (uri == null) {
        continue;
      }
      final String? target = _targetOf(packages, path, uri);
      if (target != null) {
        found.add(DartDirective(file: path, line: i + 1, uri: uri, target: target));
      }
    }
  }
  return found;
}

/// The directory of every package [tree] declares, against the name it declares itself under.
///
/// A `package:` URI of a package standing in this tree names a file of this tree, so it is resolved
/// and compared exactly like a relative one. The directory of the root package is the empty string,
/// which is what joins back to a path relative to the top of the tree.
Map<String, String> packageDirectoriesIn(SourceTree tree) {
  const String manifest = 'pubspec.yaml';
  final Map<String, String> directories = <String, String>{};
  for (final String path in tree.paths) {
    if (path != manifest && !path.endsWith('/$manifest')) {
      continue;
    }
    final String? text = tree.textOf(path);
    if (text == null) {
      continue;
    }
    final Object? document = _tryLoad(text);
    final Object? name = document is YamlMap ? document['name'] : null;
    if (name is String) {
      directories[name] = path == manifest
          ? ''
          : path.substring(0, path.length - manifest.length - 1);
    }
  }
  return directories;
}

/// The tree-relative path [uri] names from [file], or null where it names no file of this tree.
String? _targetOf(Map<String, String> packages, String file, String uri) {
  if (uri.startsWith('package:')) {
    final String rest = uri.substring('package:'.length);
    final int slash = rest.indexOf('/');
    if (slash < 0) {
      return null;
    }
    final String? directory = packages[rest.substring(0, slash)];
    if (directory == null) {
      return null;
    }
    return p.posix.normalize(p.posix.join(directory, 'lib', rest.substring(slash + 1)));
  }
  if (uri.contains(':')) {
    // `dart:` and anything else carrying a scheme. A relative path never holds a colon on the
    // platforms this tree is edited and deployed on.
    return null;
  }
  final int cut = file.lastIndexOf('/');
  return p.posix.normalize(p.posix.join(cut < 0 ? '' : file.substring(0, cut), uri));
}

Object? _tryLoad(String text) {
  try {
    return loadYaml(text);
  } on YamlException {
    return null;
  }
}

/// The one URI-carrying shape of each directive kind, matched at the start of a line.
///
/// `part of` is tried before bare `part`, so the URI taken is the one behind the whole marker. The
/// line anchor is also what keeps a counter-probe's fixtures from being read as directives of the
/// file they are written in: a directive planted as a string literal sits behind a quote and never
/// at the start of a line.
final RegExp _directiveLine = RegExp(
  r'''^\s*(?:import|export|part\s+of|part)\s+(['"])([^'"]+)\1''',
);
