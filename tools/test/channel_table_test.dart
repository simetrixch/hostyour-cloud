import 'dart:io';

import 'package:hostyour_cloud_gate/hostyour_cloud_gate.dart';
import 'package:test/test.dart';

import 'support/repository_under_check.dart';

/// The channel ceiling table is stated in exactly one file of this repository.
///
/// The audit is [ChannelTableAudit]; this file drives it over the repository, where its findings
/// must be empty, and over trees planted for the purpose that carry a second table, a missing one,
/// and — as the neighbours that matter most here — the three ways this tree already NAMES the table
/// without restating it.
///
/// It also asserts the reader directly: apps/consumer-build/templates/pipeline-release.yaml resolves
/// the table through the values chain, and a rewrite that stopped reading it would leave this check
/// holding a rule nothing consumes.
void main() {
  final Directory scratch = Directory.systemTemp.createTempSync('hostyour-channel-');
  final SourceTree tree = repositoryTree();
  final ChannelTableAudit audit = ChannelTableAudit(tree);

  tearDownAll(() => scratch.deleteSync(recursive: true));

  group('the repository', () {
    test('declares the table in $channelTableFile', () {
      expect(
        audit.statements().map((({String path, int line}) s) => s.path),
        contains(channelTableFile),
        reason: 'the ceiling every writer on the build plane checks before it writes',
      );
    });

    test('states it in no second place', () {
      final List<ChannelTableFinding> found = audit.findings();
      expect(found, isEmpty, reason: found.join('\n'));
    });

    test('this file, which plants four of them, is not judged as chart material', () {
      expect(tree.holds('tools/test/channel_table_test.dart'), isTrue);
      expect(
        audit.statements().map((({String path, int line}) s) => s.path),
        isNot(contains('tools/test/channel_table_test.dart')),
        reason:
            'the counter-probe below writes the table into this Dart source four times; an audit '
            'that scanned every tracked path would report the fixtures that prove it works',
      );
    });

    test('the build plane reads the table rather than carrying one', () {
      expect(
        tree.textOf('apps/consumer-build/templates/pipeline-release.yaml'),
        contains('.Values.global.$channelTableKey'),
        reason:
            'the gate-stage task serializes the table for its shell at render time; if it stopped '
            'resolving it from $channelTableFile, this check would be guarding a table nobody reads',
      );
    });
  });

  group('counter-probe', () {
    late List<ChannelTableFinding> found;

    setUpAll(() {
      found = ChannelTableAudit(
        SourceTree.planted(
          Directory('${scratch.path}${Platform.pathSeparator}probe')..createSync(recursive: true),
          const <String, String>{
            channelTableFile: _theDeclaration,
            'apps/probe/values.yaml': _aSecondTable,
            'apps/probe/templates/pipeline.yaml': _theThreeWaysOfNamingIt,
          },
        ),
      ).findings();
    });

    test('a second table is reported, on the line it stands on', () {
      expect(
        found,
        contains(
          predicate<ChannelTableFinding>(
            (ChannelTableFinding f) =>
                f is ASecondChannelTable && f.path == 'apps/probe/values.yaml' && f.line == 2,
          ),
        ),
        reason: 'the scan cannot go red',
      );
    });

    test('the file that only names the table is not reported', () {
      expect(
        found.whereType<ASecondChannelTable>().map((ASecondChannelTable f) => f.path),
        isNot(contains('apps/probe/templates/pipeline.yaml')),
        reason:
            'a values path, a Helm variable and a sentence in a comment all name the table without '
            'carrying one, and all three stand in this tree today',
      );
    });

    test('the declaration itself is not reported', () {
      expect(
        found.whereType<ASecondChannelTable>().map((ASecondChannelTable f) => f.path),
        isNot(contains(channelTableFile)),
      );
    });

    test('a second table in the one file is reported too', () {
      final Directory twice = Directory('${scratch.path}${Platform.pathSeparator}twice')
        ..createSync(recursive: true);
      expect(
        ChannelTableAudit(
          SourceTree.planted(twice, const <String, String>{channelTableFile: _statedTwice}),
        ).findings(),
        <Matcher>[
          predicate<ChannelTableFinding>(
            (ChannelTableFinding f) => f is ASecondChannelTable && f.line == 8,
            'the second statement, reported',
          ),
        ],
        reason: 'two tables under one roof are still two tables',
      );
    });

    test('the one file having stopped stating it is reported', () {
      final Directory gone = Directory('${scratch.path}${Platform.pathSeparator}gone')
        ..createSync(recursive: true);
      expect(
        ChannelTableAudit(
          SourceTree.planted(gone, const <String, String>{
            channelTableFile: 'global:\n  timezone: Europe/Amsterdam\n',
          }),
        ).findings(),
        <Matcher>[isA<TheChannelTableIsGone>()],
      );
    });

    test('a table that moved out of the one file is reported from both sides', () {
      final Directory moved = Directory('${scratch.path}${Platform.pathSeparator}moved')
        ..createSync(recursive: true);
      expect(
        ChannelTableAudit(
          SourceTree.planted(moved, const <String, String>{
            channelTableFile: 'global:\n  timezone: Europe/Amsterdam\n',
            'apps/probe/values.yaml': _aSecondTable,
          }),
        ).findings(),
        <Matcher>[isA<TheChannelTableIsGone>(), isA<ASecondChannelTable>()],
        reason:
            'the one file no longer declares it AND somewhere else does — the shape a move leaves '
            'behind, and the one where reporting only half of it sends somebody looking in the '
            'wrong direction',
      );
    });
  });
}

/// The table where it belongs.
const String _theDeclaration = '''
global:
  timezone: Europe/Amsterdam
  channelStages:
    alpha: [dev]
    beta: [dev, test]
    stable: [dev, test, prod]
''';

/// The same table written down a second time, with a ceiling that says something else.
const String _aSecondTable = '''
probe:
  channelStages:
    alpha: [dev, test, prod]
''';

/// The three ways this tree already names the table without restating it: through the values chain,
/// through a Helm variable holding what that resolved to, and in a sentence about it.
const String _theThreeWaysOfNamingIt = r'''
{{- $channelStages := required "probe: global.channelStages is required" .Values.global.channelStages -}}
{{- range $ch, $stages := $channelStages -}}
{{- end -}}
# One line per channel, serialized at render from global.channelStages, the one literal table.
''';

/// The one file carrying the table twice, the second one having drifted.
const String _statedTwice = '''
global:
  timezone: Europe/Amsterdam
  channelStages:
    alpha: [dev]
    beta: [dev, test]
    stable: [dev, test, prod]
release:
  channelStages:
    alpha: [dev, test]
''';
