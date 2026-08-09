/// Where the repository is, and how a test gets a scratch tree to plant into.
///
/// `dart test` runs with the package directory as the working directory, and the package is
/// tools/, so the repository is above it. The walk upwards is what makes a run started from
/// anywhere inside answer the same thing instead of quietly measuring less.
library;

import 'dart:io';

import 'package:hostyour_cloud_gate/hostyour_cloud_gate.dart';
import 'package:path/path.dart' as p;

/// The file that states what every path of this repository is. It is also how the root is found:
/// the repository is identified by its own law rather than by the package that checks it.
const String declarationFile = 'branch-classes.yaml';

/// The repository this package checks.
Directory repositoryRoot() {
  Directory directory = Directory.current.absolute;
  while (true) {
    if (File(p.join(directory.path, declarationFile)).existsSync()) {
      return directory;
    }
    final Directory parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError(
        'no $declarationFile at or above ${Directory.current.path}, so there is no repository to '
        'check and a run here would measure nothing',
      );
    }
    directory = parent;
  }
}

/// Every path git tracks in [root], relative to it and separated by `/`, sorted.
///
/// Read from git and not from the filesystem, because the distinction this repository is built on
/// is between what is TRACKED and what is not: the vendored chart dependencies, the operator's
/// credentials and the compiled binary all sit in the working tree and none of them is product.
List<String> trackedPathsIn(Directory root) {
  final ProcessResult listed = Process.runSync('git', <String>[
    '-C',
    root.path,
    'ls-files',
    '--full-name',
  ], stdoutEncoding: systemEncoding);
  if (listed.exitCode != 0) {
    throw StateError('git ls-files failed in ${root.path}: ${listed.stderr}');
  }
  final Object? out = listed.stdout;
  final List<String> paths = <String>[
    for (final String line in (out is String ? out : '').split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  paths.sort();
  return paths;
}

/// The repository as an audit sees it: its tracked paths, with their text.
SourceTree repositoryTree() {
  final Directory root = repositoryRoot();
  return SourceTree.readingFrom(root, trackedPathsIn(root));
}
