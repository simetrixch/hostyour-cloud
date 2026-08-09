import '../helm/helm.dart';
import '../installation.dart';
import '../tree/source_tree.dart';
import 'chart_family.dart';

/// The stack of values files ArgoCD hands a chart, and the block its generator injects on top.
///
/// THE ORDER IS THE WHOLE OF IT. Six files layer, and the later one wins; a render that layers them
/// differently renders something nobody deploys, and it renders successfully, which is why nothing
/// downstream can catch it. The order here is the order
/// `argocd/<stage>/apps/applicationset.yaml` writes under `helm.valueFiles`.
///
/// TWO OF THE SIX ARE NOT ON THE TRUNK. `cluster/values/<app>.yaml` is one installation's per-app
/// values and is absent here entirely; `cluster/profile.yaml` is one cluster's own file and the
/// trunk carries it as `global: {}`. Without them nothing renders — global.domain, global.vaultUrl,
/// global.booksBranch and global.catalogUrl are each required somewhere — so the fixture takes the
/// last position, which is the position cluster/profile.yaml holds on a branch.
final class ValueStack {
  /// The stack for a chart of [family] in [tree], with [installationValues] standing in for what an
  /// installation supplies.
  const ValueStack({required this.tree, required this.family, required this.installationValues});

  /// The tree the chart stands in.
  final SourceTree tree;

  /// Which generator renders it.
  final ChartFamily family;

  /// The native path of the file that stands for the two install-branch positions.
  final String installationValues;

  /// The render of `apps/[app]` for [stage], at [size] where the chart carries sizing presets.
  ChartRender renderOf(String app, String stage, {String? size}) => ChartRender(
    chartDirectory: tree.nativePathOf('apps/$app'),
    releaseName: app,
    namespace: app,
    valueFiles: _valueFilesFor(app, stage, size),
    values: _injectedFor(app, stage),
  );

  List<String> _valueFilesFor(String app, String stage, String? size) {
    switch (family) {
      // The catalog generator names a per-app file and the slave generator does not, which is why
      // these two cannot share a stack. Rendering a slave with a file its own ApplicationSet never
      // loads makes this audit green on a chart that works only because of an override no cluster
      // applies — and it is invisible on the trunk, where cluster/values/ does not exist at all.
      // What varies per slave arrives as parameters out of the cluster map, not as a values file.
      case ChartFamily.catalog:
        return <String>[
          '../../platform/values-common.yaml',
          '../../platform/values-$stage.yaml',
          if (tree.holds('apps/$app/values-common.yaml')) 'values-common.yaml',
          if (tree.holds('apps/$app/values-$stage.yaml')) 'values-$stage.yaml',
          if (tree.holds('cluster/values/$app.yaml')) '../../cluster/values/$app.yaml',
          '../../cluster/profile.yaml',
          installationValues,
        ];
      case ChartFamily.slave:
        return <String>[
          '../../platform/values-common.yaml',
          '../../platform/values-$stage.yaml',
          if (tree.holds('apps/$app/values-common.yaml')) 'values-common.yaml',
          if (tree.holds('apps/$app/values-$stage.yaml')) 'values-$stage.yaml',
          '../../cluster/profile.yaml',
          installationValues,
        ];
      case ChartFamily.sized:
        return <String>[
          '../../platform/values-common.yaml',
          '../../platform/values-$stage.yaml',
          if (size != null) 'values-size-$size.yaml',
          '../../cluster/profile.yaml',
          installationValues,
        ];
      case ChartFamily.bare:
      case ChartFamily.quota:
        return const <String>[];
      case ChartFamily.unrendered:
        return const <String>[];
    }
  }

  /// What the generator injects on top of the files, out of a registration or a cluster map.
  ///
  /// Held as the shapes the charts `required`, with values composed from the fixture domain. A
  /// chart that starts requiring one more is a render that fails with the name of the value in it,
  /// which is the finding the operator would otherwise have met on the machine.
  Map<String, String> _injectedFor(String app, String stage) => switch (family) {
    ChartFamily.slave => <String, String>{
      'slave.name': 'm1',
      'slave.branch': fixtureFqdn,
      'slave.apiHost': fixtureFqdn,
      'slave.apiPort': '16443',
      'slave.masterFqdn': fixtureFqdn,
      'slave.stage': stage,
    },
    ChartFamily.sized => switch (app) {
      'postgresql' => <String, String>{
        'externalsecret-postgres.externalSecret.vaultPath': '$stage/consumer/probe/postgres',
      },
      'unit-mongodb' => <String, String>{
        'mongodb.mode': 'standalone',
        'externalsecret-mongodb.externalSecret.vaultPath': '$stage/consumer/probe/mongodb',
      },
      _ => const <String, String>{},
    },
    // The six figures the manager resolved from its size table when it wrote the registration. The
    // chart requires every one of them rather than guessing a ceiling, because a namespace with a
    // guessed ceiling is one that stops scheduling at a number nobody chose.
    ChartFamily.quota => const <String, String>{
      'quota.requestsCpu': '2',
      'quota.requestsMemory': '4Gi',
      'quota.limitsCpu': '4',
      'quota.limitsMemory': '8Gi',
      'quota.pods': '32',
      'quota.persistentVolumeClaims': '8',
    },
    ChartFamily.catalog || ChartFamily.bare || ChartFamily.unrendered => const <String, String>{},
  };

  /// The stages a chart of [family] is rendered for.
  ///
  /// A chart with no stage of its own is rendered once; everything else once per stage, because the
  /// stage file is a position in its stack and the three do not carry the same keys.
  List<String> get stagesRendered => switch (family) {
    ChartFamily.bare || ChartFamily.quota => const <String>['dev'],
    _ => stages,
  };

  /// The sizing presets `apps/[app]` carries, or a single null where it carries none.
  List<String?> sizesOf(String app) {
    final List<String?> sizes = <String?>[
      for (final String name in tree.namesDirectlyUnder('apps/$app'))
        if (_sizePreset.firstMatch(name)?.group(1) case final String size) size,
    ];
    sizes.sort((String? a, String? b) => (a ?? '').compareTo(b ?? ''));
    return sizes.isEmpty ? const <String?>[null] : sizes;
  }
}

final RegExp _sizePreset = RegExp(r'^values-size-(.+)\.yaml$');
