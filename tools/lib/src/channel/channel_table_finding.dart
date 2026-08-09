import 'package:meta/meta.dart';

import 'channel_table.dart';

/// Something about where the channel ceiling table is written down.
///
/// Typed, so an assertion can say WHICH shape it expects instead of matching on prose, and so a
/// counter-probe can plant one shape and assert exactly that shape comes back.
@immutable
sealed class ChannelTableFinding {
  const ChannelTableFinding();

  /// What a person needs to read in order to act on this.
  String describe();

  @override
  String toString() => describe();
}

/// The table written down somewhere beside the one place it is declared.
@immutable
final class ASecondChannelTable extends ChannelTableFinding {
  /// The key is stated at [line] of [path], which is not the one declaration.
  const ASecondChannelTable({required this.path, required this.line});

  /// The path it is stated in.
  final String path;

  /// The one-based line it is stated on.
  final int line;

  @override
  String describe() =>
      '$path:$line states $channelTableKey a second time — the channel ceiling decides which '
      'release channel may reach which stage, so two tables are two answers to whether an alpha '
      'build may go to prod, and nothing says which one the next writer will read. It is declared '
      'in $channelTableFile and read from there: through the values chain as '
      '.Values.global.$channelTableKey on the build plane, and over the config route by the '
      'controller';
}

/// The one file no longer declares the table.
@immutable
final class TheChannelTableIsGone extends ChannelTableFinding {
  /// Nothing in the one file states the key.
  const TheChannelTableIsGone();

  @override
  String describe() =>
      '$channelTableFile states no $channelTableKey — every reader of the ceiling resolves it from '
      'there, so nothing enforces which channel may reach which stage, and this check has no table '
      'to hold anything against';
}
