import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import '../tree/source_tree.dart';

/// A place in this tree where a version is written down, found by its SHAPE and never by a search.
///
/// Two shapes carry an upstream version, and both are positions in a document rather than text a
/// grep could find: a chart dependency's `version:` beside a repository that is not `file://`, and
/// an image block's `tag:` beside a `repository:`. A third shape looks like the second and is not
/// one — `builds: [{name, image, tag}]` is an image this repository BUILDS, whose tag a release
/// bump moves, and versions.yaml has nothing to say about it.
///
/// The distinction is structural, so there is no exemption list to go stale: an upstream image
/// names the registry it is pulled from, and one of ours names only the build it comes out of.
@immutable
final class VersionReader {
  /// A version written at [path], for [component], as [version].
  const VersionReader({
    required this.path,
    required this.component,
    required this.version,
    required this.kind,
  });

  /// Where it stands, relative to the repository root.
  final String path;

  /// What it is a version of: a dependency name, or an image repository.
  final String component;

  /// The version itself.
  final String version;

  /// Which of the two shapes it is.
  final VersionReaderKind kind;

  /// How it is written in a finding.
  String get coordinate => '$path ($component)';
}

/// The shapes a version is written in.
enum VersionReaderKind {
  /// A dependency of `apps/<app>/Chart.yaml` fetched from a chart repository.
  chartDependency,

  /// An image block naming the registry it is pulled from.
  upstreamImage,
}

/// Every version written down in [tree], read out of the two shapes that carry one.
List<VersionReader> versionReadersIn(SourceTree tree) {
  final List<VersionReader> readers = <VersionReader>[];
  for (final String path in tree.pathsUnder('apps')) {
    final String? text = tree.textOf(path);
    if (text == null) {
      continue;
    }
    final Object? document = _tryLoad(text);
    if (document == null) {
      continue;
    }
    if (path.endsWith('/Chart.yaml')) {
      readers.addAll(_dependenciesOf(document, path));
    }
    if (path.contains('/values')) {
      readers.addAll(_upstreamImagesIn(document, path));
    }
  }
  return readers;
}

Object? _tryLoad(String text) {
  try {
    return loadYaml(text);
  } on YamlException {
    return null;
  }
}

List<VersionReader> _dependenciesOf(Object? document, String path) {
  final Object? dependencies = document is YamlMap ? document['dependencies'] : null;
  if (dependencies is! YamlList) {
    return const <VersionReader>[];
  }
  return <VersionReader>[
    for (final Object? entry in dependencies)
      if (entry is YamlMap)
        if (entry['repository'] case final String repository)
          if (!repository.startsWith('file://'))
            if (entry['name'] case final String name)
              VersionReader(
                path: path,
                component: name,
                version: '${entry['version']}',
                kind: VersionReaderKind.chartDependency,
              ),
  ];
}

List<VersionReader> _upstreamImagesIn(Object? node, String path) {
  final List<VersionReader> found = <VersionReader>[];
  void walk(Object? here) {
    if (here is YamlList) {
      for (final Object? child in here) {
        walk(child);
      }
      return;
    }
    if (here is! YamlMap) {
      return;
    }
    final Object? repository = here['repository'];
    final Object? tag = here['tag'];
    if (repository is String && tag is String) {
      found.add(
        VersionReader(
          path: path,
          component: repository,
          version: tag,
          kind: VersionReaderKind.upstreamImage,
        ),
      );
    }
    for (final Object? child in here.values) {
      walk(child);
    }
  }

  walk(node);
  return found;
}
