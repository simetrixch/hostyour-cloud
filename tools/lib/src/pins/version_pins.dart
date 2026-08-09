import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

/// platform/versions.yaml — the one place a version of this platform is decided.
///
/// Every section says who reads it, and the two kinds are not alike. [inTreeSections] are consumed
/// by charts standing right here, so a pin there can be measured against its reader. The rest are
/// consumed by the installer, which is Dart in another repository now, and by the host itself; this
/// package can say that they are present and no more, because a check that pretended to measure
/// them would be measuring its own imagination.
@immutable
final class VersionPins {
  const VersionPins._(this.components, this.sections);

  /// The pins written as [text].
  factory VersionPins.parse(String text) {
    final Object? document = loadYaml(text);
    final YamlMap root = document is YamlMap ? document : YamlMap();
    final List<PinnedComponent> components = <PinnedComponent>[];
    final Set<String> sections = <String>{};
    for (final MapEntry<Object?, Object?> entry in root.entries) {
      final Object? section = entry.key;
      if (section is! String) {
        continue;
      }
      sections.add(section);
      final Object? value = entry.value;
      if (value is YamlMap) {
        for (final MapEntry<Object?, Object?> pin in value.entries) {
          if (pin.key case final String name) {
            components.add(PinnedComponent(section: section, name: name, version: '${pin.value}'));
          }
        }
      } else {
        // A section that is one value, like `ubuntu:`. The section IS the component.
        components.add(PinnedComponent(section: section, name: section, version: '$value'));
      }
    }
    return VersionPins._(components, sections);
  }

  /// The sections whose readers are charts of this repository, so a pin there resolves here.
  ///
  /// `images:` is consumed as a container image tag and `charts:` as an upstream chart dependency
  /// version. Everything else — the bootstrap components, the Ubuntu release, the base images and
  /// the CLI tools — is installed on the host by the installer, and the file's own comments say so.
  static const Set<String> inTreeSections = <String>{'images', 'charts'};

  /// The sections this package knows, against a word saying who reads each.
  ///
  /// A section in the file that is not here is one nobody wired up, and a section here that the
  /// file has lost is one that vanished. Both happened during the migration and both were found by
  /// reading.
  static const Map<String, String> knownSections = <String, String>{
    'images': 'a container image tag in a chart of this repository',
    'charts': 'an upstream chart dependency version in apps/*/Chart.yaml',
    'bootstrap': 'the installer, which stands up these components before ArgoCD reconciles',
    'ubuntu': 'the installer, which refuses any other release in its preflight',
    'baseImages': 'the Dockerfiles of the images this platform builds',
    'cliTools': 'the installer, which puts these on every host under /usr/local/bin',
  };

  /// Every component pinned, in document order.
  final List<PinnedComponent> components;

  /// The names of the sections the file carries.
  final Set<String> sections;

  /// Every version any section pins.
  Set<String> get everyVersion => <String>{
    for (final PinnedComponent component in components) component.version,
  };

  /// The components of the sections whose readers are in this tree.
  List<PinnedComponent> get resolvableHere => <PinnedComponent>[
    for (final PinnedComponent component in components)
      if (inTreeSections.contains(component.section)) component,
  ];
}

/// One component, and the version this platform runs of it.
@immutable
final class PinnedComponent {
  /// The component [name] of [section], pinned at [version].
  const PinnedComponent({required this.section, required this.name, required this.version});

  /// Which section it stands in, which is who reads it.
  final String section;

  /// What it is called.
  final String name;

  /// What this platform runs.
  final String version;

  /// How it is written in a finding.
  String get coordinate => '$section.$name';
}
