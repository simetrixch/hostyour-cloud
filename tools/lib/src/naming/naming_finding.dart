import 'package:meta/meta.dart';

import 'abolished_word.dart';

/// Something in this tree carrying a name that names nothing.
///
/// Typed, so an assertion can say WHICH shape it expects instead of matching on prose, and so a
/// counter-probe can plant one shape and assert exactly that shape comes back.
@immutable
sealed class NamingFinding {
  const NamingFinding();

  /// What a person needs to read in order to act on this.
  String describe();

  @override
  String toString() => describe();
}

/// A file name or a directory name carrying an abolished word.
@immutable
final class AbolishedWordInAName extends NamingFinding {
  /// [segment] of [path] carries [word].
  const AbolishedWordInAName({required this.path, required this.segment, required this.word});

  /// The path the name stands in.
  final String path;

  /// The one segment of it that carries the word — a directory name, or the file name.
  final String segment;

  /// What it carries.
  final AbolishedWord word;

  @override
  String describe() => '$path — "$segment" carries "${word.word}": ${word.because}';
}

/// The tree offered no names, so this audit decided nothing.
@immutable
final class NothingWasNamed extends NamingFinding {
  /// No path was walked.
  const NothingWasNamed();

  @override
  String describe() =>
      'no path was walked, so no name was judged — a check that measures nothing reads exactly '
      'like one that passed';
}
