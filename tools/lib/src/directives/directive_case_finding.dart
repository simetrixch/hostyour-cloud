import 'package:meta/meta.dart';

import 'dart_directive.dart';

/// A directive whose spelling is not the spelling of the path it names.
@immutable
final class DirectiveCaseFinding {
  /// [directive] resolves to a path this tree tracks as [tracked], under a different spelling.
  const DirectiveCaseFinding({required this.directive, required this.tracked});

  /// The directive that is spelled wrong.
  final DartDirective directive;

  /// The path as git records it, which is the name a checkout writes to disk.
  final String tracked;

  /// What a person needs to read in order to act on this.
  String describe() =>
      "${directive.coordinate} writes '${directive.uri}', which resolves to ${directive.target}, "
      'and this tree tracks $tracked — Windows opens either spelling and a case-sensitive checkout '
      'opens only the tracked one, so this resolves on the machine it was written on and is an '
      'unresolved import on every Linux clone of the same commit; spell the directive the way the '
      'tracked path is spelled';

  @override
  String toString() => describe();
}
