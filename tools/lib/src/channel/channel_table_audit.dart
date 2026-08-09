import '../tree/source_tree.dart';
import 'channel_table.dart';
import 'channel_table_finding.dart';

/// The channel ceiling table is stated in exactly one file of this tree.
///
/// WHAT THE TABLE DECIDES is which stages a release channel may reach — `alpha` to dev, `beta` to
/// dev and test, `stable` everywhere — and the channel is read from the release tag itself. It is
/// the ceiling the build plane checks before it clones anything and before it writes a pin, so a
/// second copy of it is a second answer to whether an alpha build may go to prod.
///
/// WHAT IT MEASURES IS THIS REPOSITORY AND NOTHING ELSE. The controller reads the table over its
/// config route from the file this audit points at, which is why there is nothing here to compare it
/// against: a check that looked for a copy in another repository would find nothing whether that
/// repository agreed or was not there at all, and would report those two as the same green.
///
/// A READING IS NOT A STATEMENT. `.Values.global.channelStages` in a chart, `$channelStages` in a
/// Helm variable and the word in a comment all name the table without carrying one, and
/// [channelTableStatement] is what draws that line. What is scanned is the chart material
/// ([SourceTree.chartMaterial]): a table that decides a deployment is a table in the values chain,
/// and the gate's own Dart carries the shape only where it plants one to prove this audit can go
/// red.
final class ChannelTableAudit {
  /// The audit of [tree].
  const ChannelTableAudit(this.tree);

  /// The tree being decided about.
  final SourceTree tree;

  /// Everything wrong with where the channel ceiling is written down.
  List<ChannelTableFinding> findings() => <ChannelTableFinding>[
    ...theOneTableItself(),
    ...tablesBesideTheOne(),
  ];

  /// Where the table is stated in the chart material, in path order and in the order the statements
  /// stand in a file.
  List<({String path, int line})> statements() {
    final List<({String path, int line})> found = <({String path, int line})>[];
    for (final String path in tree.chartMaterial) {
      final String? text = tree.textOf(path);
      if (text == null) {
        continue;
      }
      final List<String> lines = SourceTree.linesOf(text);
      for (int at = 0; at < lines.length; at++) {
        if (channelTableStatement.hasMatch(lines[at])) {
          found.add((path: path, line: at + 1));
        }
      }
    }
    return found;
  }

  /// The one file having stopped stating the table.
  List<ChannelTableFinding> theOneTableItself() {
    final bool stated = statements().any(
      (({String path, int line}) statement) => statement.path == channelTableFile,
    );
    return stated
        ? const <ChannelTableFinding>[]
        : const <ChannelTableFinding>[TheChannelTableIsGone()];
  }

  /// Every statement of the table beside the one in [channelTableFile].
  ///
  /// The one file's own first statement is the declaration and is passed over; a second one in that
  /// same file is reported like any other, because two tables under one roof are still two tables.
  List<ChannelTableFinding> tablesBesideTheOne() {
    final List<ChannelTableFinding> found = <ChannelTableFinding>[];
    bool theDeclaration = false;
    for (final ({String path, int line}) statement in statements()) {
      if (statement.path == channelTableFile && !theDeclaration) {
        theDeclaration = true;
        continue;
      }
      found.add(ASecondChannelTable(path: statement.path, line: statement.line));
    }
    return found;
  }
}
