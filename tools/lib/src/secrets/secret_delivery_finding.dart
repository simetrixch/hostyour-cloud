import 'package:meta/meta.dart';

import 'refresh_field.dart';

/// An ExternalSecret of this tree that does not carry the platform-wide secret delivery rule.
///
/// Typed, so an assertion can say WHICH shape it expects instead of matching on prose, and so a
/// counter-probe can plant one shape and assert exactly that shape comes back.
@immutable
sealed class SecretDeliveryFinding {
  const SecretDeliveryFinding();

  /// What a person needs to read in order to act on this.
  String describe();

  @override
  String toString() => describe();
}

/// A field of the rule stated as something other than its literal.
@immutable
final class RefreshFieldIsNotTheLiteral extends SecretDeliveryFinding {
  /// [field] stands at [line] of [path] carrying [value] instead of its literal.
  const RefreshFieldIsNotTheLiteral({
    required this.path,
    required this.line,
    required this.field,
    required this.value,
  });

  /// The path the document stands in.
  final String path;

  /// The one-based line the field is stated on.
  final int line;

  /// The field of the rule.
  final RefreshField field;

  /// What stands after the colon, as the file writes it.
  final String value;

  @override
  String describe() =>
      '$path:$line — ${field.key} carries "$value" where every ExternalSecret on this platform '
      'fixes the literal ${field.literal}: ${field.because}. A value or a template expression in '
      'this position is a per-app override, and an override is how ONE namespace ends up on a '
      'different delivery model than every other while every rendered manifest still looks '
      'orderly';
}

/// A document of the kind that states a field of the rule nowhere.
@immutable
final class RefreshFieldIsMissing extends SecretDeliveryFinding {
  /// The ExternalSecret whose `kind:` stands at [kindLine] of [path] states no [field].
  const RefreshFieldIsMissing({required this.path, required this.kindLine, required this.field});

  /// The path the document stands in.
  final String path;

  /// The one-based line the document's `kind: ExternalSecret` stands on.
  final int kindLine;

  /// The field of the rule that is stated nowhere in it.
  final RefreshField field;

  @override
  String describe() =>
      '$path:$kindLine — this ExternalSecret states no ${field.key}, so external-secrets applies '
      'its own default here and the platform rule is not what this namespace runs on: '
      '${field.because}';
}

/// The tree held no document of the kind, so this audit decided nothing.
@immutable
final class NoExternalSecretWasRead extends SecretDeliveryFinding {
  /// Nothing of kind ExternalSecret was found to judge.
  const NoExternalSecretWasRead();

  @override
  String describe() =>
      'no document of kind ExternalSecret was read, so no delivery rule was judged — a check that '
      'measures nothing reads exactly like one that passed';
}
