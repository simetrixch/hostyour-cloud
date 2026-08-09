import 'package:meta/meta.dart';

/// Something wrong with the values files the generators of this tree name.
///
/// A finding is typed because an assertion over a list of pre-formatted strings matches on prose: it
/// passes for the wrong reason the day somebody improves the wording, and it cannot say which KIND
/// of thing was found without reading English. Every subtype carries the coordinates of what it
/// found, and [describe] is for the person reading a red run.
@immutable
sealed class ValueFilesFinding {
  /// A finding.
  const ValueFilesFinding();

  /// What a person needs to read in order to act on this.
  String describe();

  @override
  String toString() => describe();
}

/// A generator names a values file of this repository that is product, and it is not here.
@immutable
final class ProductValuesFileIsGone extends ValueFilesFinding {
  /// [manifest] names [entry] on [line], which resolves to [path], and nothing is there.
  const ProductValuesFileIsGone({
    required this.manifest,
    required this.line,
    required this.entry,
    required this.path,
  });

  /// The manifest that names it.
  final String manifest;

  /// The one-based line the entry stands on.
  final int line;

  /// The entry as written.
  final String entry;

  /// Where the file would have to be.
  final String path;

  @override
  String describe() =>
      '$manifest:$line names `$entry`, which is $path, and this repository does not carry it. '
      'branch-classes.yaml calls that path product, so it goes to every installation and no '
      'installation may be without it. The generator sets ignoreMissingValueFiles, so no cluster '
      'reports this: every Application renders from whatever the remaining files happen to say';
}

/// A generator names a values file nothing in its own manifest places.
@immutable
final class ValueFileCannotBePlaced extends ValueFilesFinding {
  /// [manifest] names [entry] on [line], and it could not be placed for the reason in [why].
  const ValueFileCannotBePlaced({
    required this.manifest,
    required this.line,
    required this.entry,
    required this.why,
  });

  /// The manifest that names it.
  final String manifest;

  /// The one-based line the entry stands on.
  final int line;

  /// The entry as written.
  final String entry;

  /// Why it could not be placed.
  final String why;

  @override
  String describe() =>
      '$manifest:$line names `$entry` and nothing in that manifest says which file it is: $why. '
      'An entry nothing can place is an entry nothing can require, so it is reported rather than '
      'passed over — a check silently short one name is a check that agrees with everything';
}

/// A manifest says it names values files and the reader took none out of it.
@immutable
final class ValueFilesWereNotRead extends ValueFilesFinding {
  /// [manifest] carries a `valueFiles:` list the reader could not follow.
  const ValueFilesWereNotRead(this.manifest);

  /// The manifest.
  final String manifest;

  @override
  String describe() =>
      '$manifest writes `valueFiles:` and this check read no entry out of it, so whatever it names '
      'is unmeasured. Either the list is written in a shape the reader does not follow — a flow '
      'sequence on one line — or the reader has stopped matching the files it is pointed at';
}

/// No generator of this tree names a values file.
@immutable
final class NoGeneratorNamesAValuesFile extends ValueFilesFinding {
  /// Nothing was read.
  const NoGeneratorNamesAValuesFile();

  @override
  String describe() =>
      'no ApplicationSet of this tree names a values file, so this check decided nothing about it '
      '— and a green run that read nothing is indistinguishable from one that found nothing wrong';
}
