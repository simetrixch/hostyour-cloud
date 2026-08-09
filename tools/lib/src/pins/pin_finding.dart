import 'package:meta/meta.dart';

import '../installation.dart';

/// Something wrong with where this platform's versions are decided.
@immutable
sealed class PinFinding {
  const PinFinding();

  /// What a person needs to read in order to act on this.
  String describe();

  @override
  String toString() => describe();
}

/// A version written in the tree that platform/versions.yaml does not pin.
@immutable
final class VersionDecidedElsewhere extends PinFinding {
  /// [component] is at [version] in [path], and no pin carries that value.
  const VersionDecidedElsewhere({
    required this.path,
    required this.component,
    required this.version,
  });

  /// Where the version stands.
  final String path;

  /// What it is a version of.
  final String component;

  /// The version.
  final String version;

  @override
  String describe() =>
      '$path pins $component at $version and platform/versions.yaml carries no such value — that '
      'file is the ONE place a version of this platform is decided, and a second place is a raise '
      'somebody will make in one of them';
}

/// A component nothing in this tree reads.
@immutable
final class ComponentWithoutAReader extends PinFinding {
  /// [coordinate] at [version] has no reader on a [role] at [stage].
  const ComponentWithoutAReader({
    required this.coordinate,
    required this.version,
    required this.stage,
    required this.role,
  });

  /// Which component, as `<section>.<name>`.
  final String coordinate;

  /// What it is pinned at.
  final String version;

  /// The stage of the branch it has no reader on.
  final String stage;

  /// The role of that branch.
  final ClusterRole role;

  @override
  String describe() =>
      '$coordinate is pinned at $version and nothing on a ${role.name} branch at stage $stage reads '
      'it — the role is known when the install branch is generated and the branch then carries '
      'exactly one value per component, so a component that resolves for one branch and not the '
      'other produces a hole that is found on the machine';
}

/// One image at two versions.
@immutable
final class ImageAtTwoVersions extends PinFinding {
  /// [repository] is at [versions] across [paths].
  const ImageAtTwoVersions({required this.repository, required this.versions, required this.paths});

  /// The image.
  final String repository;

  /// The versions it is pinned at, sorted.
  final List<String> versions;

  /// Where each stands, sorted.
  final List<String> paths;

  @override
  String describe() =>
      '$repository is pinned at ${versions.join(' and ')} in ${paths.join(', ')} — one image runs '
      'one version, and two clusters of this platform would then run different ones';
}

/// The set of sections in platform/versions.yaml is not the set anything knows about.
@immutable
final class SectionNobodyReads extends PinFinding {
  /// [section] is in the file and nothing here knows who reads it.
  const SectionNobodyReads(this.section);

  /// The section.
  final String section;

  @override
  String describe() =>
      'platform/versions.yaml carries the section "$section" and nothing states who reads it — a '
      'pin whose reader is unknown is one nobody can verify and everybody pays to download';
}

/// A section that was there and is gone.
@immutable
final class SectionVanished extends PinFinding {
  /// [section] is known and the file no longer carries it.
  const SectionVanished(this.section);

  /// The section.
  final String section;

  @override
  String describe() =>
      'platform/versions.yaml no longer carries the section "$section" — two pins were already '
      'removed once because their only reader had moved to another repository, and that was found '
      'by reading rather than by anything measuring it';
}
