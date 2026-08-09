import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The tree of files an audit decides about.
///
/// An audit that can only read the repository it lives in cannot be shown to work: it answers
/// "nothing found" when the tree is clean and when the scan is broken, and those are the same
/// output. So every audit in this package takes a [SourceTree] — [SourceTree.readingFrom] for the
/// real repository, [SourceTree.planted] for the scratch tree a counter-probe writes.
///
/// A PLANTED TREE IS REALLY ON DISK, and that is not an accident of convenience. helm opens the
/// charts it renders and the domain stamp reads the first two bytes of a file to see whether it is
/// a script, so a tree that existed only in memory could be handed to neither, and the audits
/// would have to be driven two different ways depending on which tree they were looking at.
///
/// Paths are relative to the root and separated by `/` on every platform, so a planted tree and a
/// read one are described the same way and an assertion reads the same on Windows and on Linux.
final class SourceTree {
  const SourceTree._(this.root, this._contents);

  /// The tree at [root] holding exactly [paths], with the text of each read from disk.
  ///
  /// The paths are given rather than discovered, because the distinction this repository is built
  /// on is between what git TRACKS and what merely sits in the working directory: the vendored
  /// chart dependencies, the operator's credentials and the compiled binary are all on disk and
  /// none of them is part of the product.
  factory SourceTree.readingFrom(Directory root, List<String> paths) {
    final Map<String, String?> contents = <String, String?>{};
    for (final String path in paths) {
      contents[path] = _textOf(File(p.join(root.path, p.joinAll(path.split('/')))));
    }
    return SourceTree._(root, contents);
  }

  /// Writes [files] under [root] and answers with the tree that results.
  ///
  /// What is written is what is then read back, so a counter-probe measures the same bytes an
  /// audit would meet in the repository rather than a description of them.
  factory SourceTree.planted(Directory root, Map<String, String> files) {
    for (final MapEntry<String, String> entry in files.entries) {
      final File file = File(p.join(root.path, p.joinAll(entry.key.split('/'))));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    return SourceTree.readingFrom(root, files.keys.toList(growable: false));
  }

  /// Where the tree stands, for a tool that has to be handed a path.
  final Directory root;

  final Map<String, String?> _contents;

  /// Every path in the tree, sorted.
  List<String> get paths {
    final List<String> all = _contents.keys.toList(growable: false)..sort();
    return all;
  }

  /// The paths of the chart material — `.yaml` and `.tpl` — sorted.
  ///
  /// WHAT AN AUDIT THAT SCANS CONTENT MAY READ. .gitattributes calls these two "the chart material
  /// a cluster renders", and they are what a rule about a manifest, a values file or a chart helper
  /// is a rule about. Everything else tracked here is the gate's own Dart, and the gate's
  /// counter-probes plant the exact shapes those audits look for — so a content scan over every path
  /// would report the fixtures that prove it works, on a file no cluster ever sees.
  ///
  /// An audit about NAMES or about BYTES reads [paths] instead: a carriage return in a Dart file and
  /// an abolished word in its name are defects wherever they stand.
  List<String> get chartMaterial => <String>[
    for (final String path in paths)
      if (path.endsWith('.yaml') || path.endsWith('.tpl')) path,
  ];

  /// Whether [path] is in the tree.
  bool holds(String path) => _contents.containsKey(path);

  /// The text of [path], or null when it is not in the tree, is not on disk, or is not text.
  ///
  /// A file holding a zero byte is counted as present and left unread: a byte scan over an image
  /// reports matches nobody can act on.
  String? textOf(String path) => _contents[path];

  /// The native path of [path], for a tool that opens files itself.
  String nativePathOf(String path) => p.join(root.path, p.joinAll(path.split('/')));

  /// The paths under [directory], one directory level deep, as their last segment, sorted.
  List<String> namesDirectlyUnder(String directory) {
    final String prefix = '$directory/';
    final Set<String> names = <String>{};
    for (final String path in _contents.keys) {
      if (!path.startsWith(prefix)) {
        continue;
      }
      final String rest = path.substring(prefix.length);
      final int cut = rest.indexOf('/');
      names.add(cut < 0 ? rest : rest.substring(0, cut));
    }
    final List<String> sorted = names.toList(growable: false)..sort();
    return sorted;
  }

  /// The paths in [directory] and under it, sorted.
  List<String> pathsUnder(String directory) {
    final String prefix = '$directory/';
    final List<String> under =
        _contents.keys.where((String path) => path.startsWith(prefix)).toList(growable: false)
          ..sort();
    return under;
  }

  /// The lines of [text], without their terminators.
  static List<String> linesOf(String text) => const LineSplitter().convert(text);

  static String? _textOf(File file) {
    if (!file.existsSync()) {
      return null;
    }
    final List<int> bytes = file.readAsBytesSync();
    if (bytes.contains(0)) {
      return null;
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}
