import 'package:meta/meta.dart';

/// This repository, written the way the manifests of this repository write it.
///
/// A source of an ApplicationSet states by URL which repository it reads, and this gate can only
/// decide about a file standing in THIS one — the working tree is the only repository the gate may
/// assume is on the machine. The owner and name of it also stand in apps/manager/values-common.yaml
/// as `github.repo`, which is where the manager writes its registrations back to.
const String thisRepository = 'https://github.com/simetrixch/hostyour-cloud.git';

/// Where a values file an ApplicationSet names actually stands.
///
/// THIS IS THE WHOLE DIFFICULTY, and it is not the comparison that follows it. `helm.valueFiles`
/// is a list of names, and four kinds of thing wear the same shape in it: a file of this repository
/// that must be here, a file of another repository that this gate cannot see, a name whose path
/// segment arrives from a registration, and a name nothing in the manifest explains. Only the first
/// can be required, so a check that did not tell them apart would either demand files that are not
/// ours to demand, or demand nothing at all.
@immutable
sealed class ValueFileStanding {
  /// A standing.
  const ValueFileStanding();
}

/// A path of this repository, whether or not the file is there.
@immutable
final class InThisRepository extends ValueFileStanding {
  /// The file stands at [path], relative to the repository root.
  const InThisRepository(this.path);

  /// Where it stands.
  final String path;
}

/// A path of a repository this gate does not read.
@immutable
final class InAnotherRepository extends ValueFileStanding {
  /// The source it rides on names [repository].
  const InAnotherRepository(this.repository);

  /// What the manifest writes where the repository is named — a URL, a placeholder a branch run
  /// stamps, or a generator parameter.
  final String repository;
}

/// A path whose own text carries a generator parameter this repository cannot supply.
@immutable
final class NamedByAGeneratorParameter extends ValueFileStanding {
  /// The manifest writes [expression] into the path, and nothing here says what it becomes.
  const NamedByAGeneratorParameter(this.expression);

  /// The go-template expression, as the manifest writes it.
  final String expression;
}

/// A path nothing in its own manifest places.
@immutable
final class Unplaceable extends ValueFileStanding {
  /// It could not be placed, for the reason in [why].
  const Unplaceable(this.why);

  /// Why.
  final String why;
}

/// One entry of one `helm.valueFiles` list, and where the file it names stands.
@immutable
final class NamedValueFile {
  /// The entry written on [line] of [manifest] as [entry], standing at [standing].
  ///
  /// One entry can produce several of these: a name carrying a parameter the manifest's own list
  /// generator states as a literal is every value that list holds, and each of those is a file that
  /// has to be there on its own.
  const NamedValueFile({
    required this.manifest,
    required this.line,
    required this.entry,
    required this.standing,
  });

  /// The manifest that names it, relative to the repository root.
  final String manifest;

  /// The one-based line the entry stands on, so it is the number an editor shows.
  final int line;

  /// The entry as written, the list dash and any quotes removed.
  final String entry;

  /// Where the file it names stands.
  final ValueFileStanding standing;
}
