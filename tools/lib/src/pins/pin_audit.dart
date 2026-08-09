import '../branch/branch_class_audit.dart';
import '../installation.dart';
import '../stamp/role_stamp.dart';
import '../tree/source_tree.dart';
import 'pin_finding.dart';
import 'version_pins.dart';
import 'version_reader.dart';

/// Every component of this platform resolves, for both roles and at every stage.
///
/// platform/versions.yaml is the one place a version is decided, and nothing checked that the
/// decision arrives anywhere. A pin nobody reads is a version this platform does not actually run;
/// a version written in the tree that no pin carries is a second place somebody will raise instead
/// of the first.
///
/// BOTH ROLES, AND ALL THREE STAGES, because the branch an installation runs is not the trunk. The
/// role stamp reduces it to one stage and, on a role without the master part, removes the books —
/// so a component whose only reader stands in a file that branch does not carry produces a branch
/// with a hole in it, and the hole is found on the machine.
///
/// WHAT UPSTREAM HAS NOW IS NOT MEASURED HERE, and never will be. A version appearing on the
/// internet turning this tree red would make red stop meaning "the tree is sound", and a gate whose
/// red means two different things is a gate people learn to ignore.
final class PinAudit {
  /// The audit of [tree] against the pins in [pins].
  const PinAudit({required this.tree, required this.pins});

  /// The tree being decided about.
  final SourceTree tree;

  /// What it pins.
  final VersionPins pins;

  /// Everything wrong with where this platform's versions are decided.
  List<PinFinding> findings() => <PinFinding>[
    ...sectionsNobodyReads(),
    ...versionsDecidedElsewhere(),
    ...imagesAtTwoVersions(),
    ...componentsWithoutAReader(),
  ];

  /// Sections that arrived without a reader, and sections that vanished.
  List<PinFinding> sectionsNobodyReads() => <PinFinding>[
    for (final String section in pins.sections)
      if (!VersionPins.knownSections.containsKey(section)) SectionNobodyReads(section),
    for (final String section in VersionPins.knownSections.keys)
      if (!pins.sections.contains(section)) SectionVanished(section),
  ];

  /// Versions written in the tree that no pin carries.
  List<PinFinding> versionsDecidedElsewhere() {
    final Set<String> pinned = pins.everyVersion;
    return <PinFinding>[
      for (final VersionReader reader in versionReadersIn(tree))
        if (!pinned.contains(reader.version))
          VersionDecidedElsewhere(
            path: reader.path,
            component: reader.component,
            version: reader.version,
          ),
    ];
  }

  /// One image pinned at two versions in two places.
  List<PinFinding> imagesAtTwoVersions() {
    final Map<String, Map<String, List<String>>> byRepository =
        <String, Map<String, List<String>>>{};
    for (final VersionReader reader in versionReadersIn(tree)) {
      if (reader.kind != VersionReaderKind.upstreamImage) {
        continue;
      }
      byRepository
          .putIfAbsent(reader.component, () => <String, List<String>>{})
          .putIfAbsent(reader.version, () => <String>[])
          .add(reader.path);
    }
    final List<PinFinding> found = <PinFinding>[];
    for (final MapEntry<String, Map<String, List<String>>> image in byRepository.entries) {
      if (image.value.length < 2) {
        continue;
      }
      final List<String> versions = image.value.keys.toList(growable: false)..sort();
      final List<String> paths = <String>[
        for (final List<String> where in image.value.values) ...where,
      ]..sort();
      found.add(ImageAtTwoVersions(repository: image.key, versions: versions, paths: paths));
    }
    return found;
  }

  /// Components of the in-tree sections that no surviving file reads, per stage and per role.
  List<PinFinding> componentsWithoutAReader() {
    final List<VersionReader> readers = versionReadersIn(tree);
    final List<PinFinding> found = <PinFinding>[];
    for (final String stage in stages) {
      for (final ClusterRole role in ClusterRole.values) {
        final RoleStamp stamp = RoleStamp(
          stage: stage,
          role: role,
          ownMap: BranchClassAudit.ownClusterMap,
        );
        final Set<String> surviving = <String>{
          for (final VersionReader reader in readers)
            if (stamp.verdictOn(reader.path) is Kept) reader.version,
        };
        for (final PinnedComponent component in pins.resolvableHere) {
          if (surviving.contains(component.version)) {
            continue;
          }
          found.add(
            ComponentWithoutAReader(
              coordinate: component.coordinate,
              version: component.version,
              stage: stage,
              role: role,
            ),
          );
        }
      }
    }
    return found;
  }
}
