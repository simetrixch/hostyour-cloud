import 'package:yaml/yaml.dart';

import '../installation.dart';
import '../tree/source_tree.dart';
import 'chart_family.dart';

/// What the ArgoCD manifests of one tree say is deployed, and by which generator.
///
/// Read from the manifests and never from a list kept here. The catalog's chart source is
/// `path: "apps/{{ .name }}"`, so a catalog NAME is also a chart DIRECTORY, and a name with no
/// directory is an Application that can never sync — on every stage at once. That is exactly the
/// kind of thing nothing in this repository was able to notice.
final class ApplicationCatalog {
  /// The catalog of [tree].
  ApplicationCatalog(this.tree);

  /// The tree whose manifests were read.
  final SourceTree tree;

  final Map<String, List<String>> _namesByStage = <String, List<String>>{};
  List<String>? _literalPaths;

  /// The apps the platform ApplicationSet deploys at [stage], in the order it lists them.
  List<String> namesAt(String stage) => _namesByStage.putIfAbsent(stage, () {
    final String? manifest = tree.textOf('argocd/$stage/apps/applicationset.yaml');
    if (manifest == null) {
      return const <String>[];
    }
    final Object? elements = _dig(loadYaml(manifest), const <Object>[
      'spec',
      'generators',
      0,
      'merge',
      'generators',
      0,
      'list',
      'elements',
    ]);
    if (elements is! YamlList) {
      return const <String>[];
    }
    return <String>[
      for (final Object? element in elements)
        if (element is YamlMap)
          if (element['name'] case final String name) name,
    ];
  });

  /// Every name any stage's catalog carries, sorted.
  List<String> get everyCatalogName {
    final Set<String> names = <String>{for (final String stage in stages) ...namesAt(stage)};
    final List<String> sorted = names.toList(growable: false)..sort();
    return sorted;
  }

  /// The chart paths the manifests name outright, as `apps/<name>`, sorted.
  ///
  /// The catalog's own source is templated and never matches this; everything else — the four unit
  /// charts and apps/slave — is a literal in a consumers, tenants or slaves generator.
  List<String> get literalChartPaths => _literalPaths ??= _readLiteralChartPaths();

  /// Which family renders [app].
  ///
  /// The catalog half is read from the manifest. The literal half cannot be: which files each of
  /// those generators layers is not something a manifest states in a form anything but an
  /// ApplicationSet controller can read, so it is stated here against the manifest that decides
  /// it — `argocd/prod/apps/slaves-appset.yaml` for the slave, and
  /// `argocd/prod/apps/consumers-appset.yaml` for the four unit charts, whose four sources stand
  /// there in this order.
  ChartFamily familyOf(String app) {
    if (everyCatalogName.contains(app)) {
      return ChartFamily.catalog;
    }
    if (!literalChartPaths.contains('apps/$app')) {
      return ChartFamily.unrendered;
    }
    return switch (app) {
      'slave' => ChartFamily.slave,
      'unit-networkpolicy' => ChartFamily.bare,
      'unit-quota' => ChartFamily.quota,
      _ => ChartFamily.sized,
    };
  }

  List<String> _readLiteralChartPaths() {
    final Set<String> found = <String>{};
    for (final String path in tree.pathsUnder('argocd')) {
      final String? text = tree.textOf(path);
      if (text == null) {
        continue;
      }
      for (final RegExpMatch match in _literalPath.allMatches(text)) {
        final String? named = match.group(1);
        if (named != null) {
          found.add(named);
        }
      }
    }
    final List<String> sorted = found.toList(growable: false)..sort();
    return sorted;
  }

  static Object? _dig(Object? node, List<Object> keys) {
    Object? here = node;
    for (final Object key in keys) {
      here = switch (here) {
        final YamlMap map => map[key],
        final YamlList list when key is int && key < list.length => list[key],
        _ => null,
      };
      if (here == null) {
        return null;
      }
    }
    return here;
  }
}

final RegExp _literalPath = RegExp(r'path:\s*(apps/[a-z0-9-]+)\s*$', multiLine: true);
