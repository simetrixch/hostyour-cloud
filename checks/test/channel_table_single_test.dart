import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';

/// channel-table-single — over the real tree, and over planted ones.
///
/// **What this is guarding.** The channel a release tag carries decides which stages that release
/// may reach, and three points enforce it. The `gate-stage` task of a `<unit>-release` Pipeline and
/// the `bump` task before every pin write both read the table as the `CHANNEL_STAGES` env var that
/// `apps/consumer-build/templates/pipeline-release.yaml` renders from `.Values.global.channelStages`
/// — the values chain. A cluster release reads it another way: `ceilingCheck` in
/// `hostyour-manager/server/domains/runs/defs/release.ts` runs as the `attest-target` step's own
/// check, ahead of the `set-pin` step, and `readChannelStages` reads
/// `platform/values-common.yaml` off the trunk through the Controller's git port. All three read one
/// table. A second statement of it drifts the day either one is edited, and the permissive direction
/// is silent — an `alpha` release is gated, pinned and deployed to `prod` while every side reports
/// success.
///
/// **Why the words are read for the real tree and planted for the shape tests.** A list of channel
/// names inside the check would be a second statement of half the table, standing in the guard that
/// refuses second statements — so the tree is judged with the words the table itself is made of.
/// The fixtures below plant those words as input, which is the one place they are data and not a
/// second truth.
///
/// **Why the checks package is not scanned.** Nothing on a cluster reads it, so a channel and a
/// stage standing together in it gates no release; and the probes here state the table on purpose.
void main() {
  final Directory repository = Directory.current.parent;
  final String ownPackage = _leafOf(Directory.current.path);
  const String stated = 'platform/values-common.yaml';

  group('the tree as it stands', () {
    test('the channel ceiling is stated in one file and nowhere else in the tracked tree', () {
      final Map<String, List<String>> ceiling = channelCeilingIn(
        File('${repository.path}/$stated').readAsStringSync(),
      );
      expect(
        ceiling,
        isNotEmpty,
        reason:
            '$stated states no global.$channelStagesKey — the table this check reads its words out '
            'of was moved or renamed, and a scan for no word finds nothing anywhere',
      );

      final Set<String> channels = ceiling.keys.toSet();
      final Set<String> stages = <String>{for (final List<String> each in ceiling.values) ...each};
      expect(stages, isNotEmpty, reason: 'no channel of the table may reach any stage');

      expect(
        ceilingStatementsIn(
          where: stated,
          text: File('${repository.path}/$stated').readAsStringSync(),
          channels: channels,
          stages: stages,
        ),
        isNotEmpty,
        reason: 'the table is stated in $stated but the scan does not read it there',
      );

      final Map<String, String> files = _trackedTextOf(repository, except: ownPackage);
      expect(files, isNotEmpty, reason: 'a check over nothing reads like a pass');

      expect(
        auditChannelTableSingle(
          files: files,
          statedIn: stated,
          channels: channels,
          stages: stages,
        ).map((SecondCeiling each) => each.toString()),
        isEmpty,
      );
    });
  });

  group('what the values file states', () {
    test('the table is read out of global, where the values chain propagates it from', () {
      expect(
        channelCeilingIn('''
global:
  releaseTagFilter: 'x'
  channelStages:
    alpha: [dev]
    beta: [dev, test]
'''),
        <String, List<String>>{
          'alpha': <String>['dev'],
          'beta': <String>['dev', 'test'],
        },
      );
    });

    test('a file that states no table reads as nothing, which every caller must refuse over', () {
      // Empty is not "no channel may reach anything": an audit driven by no word finds nothing and
      // reads exactly like a tree that states the ceiling once. The real-tree test asserts the
      // table is there before it judges anything against it.
      expect(channelCeilingIn('global:\n  domain: example.test\n'), isEmpty);
      expect(channelCeilingIn('channelStages:\n  alpha: [dev]\n'), isEmpty);
    });
  });

  group('what a statement is', () {
    const Set<String> channels = <String>{'alpha', 'beta', 'stable'};
    const Set<String> stages = <String>{'dev', 'test', 'prod'};

    List<CeilingStatement> read(String text) =>
        ceilingStatementsIn(where: 'planted.yaml', text: text, channels: channels, stages: stages);

    test('the table copied as a flow mapping is read, one statement per channel', () {
      final List<CeilingStatement> found = read('''
global:
  channelStages:
    alpha: [dev]
    beta: [dev, test]
    stable: [dev, test, prod]
''');
      expect(found, hasLength(3));
      expect(found.first.line, 3);
      expect(found.first.channels, <String>{'alpha'});
      expect(found.first.stages, <String>{'dev'});
      expect(found.last.stages, <String>{'dev', 'test', 'prod'});
    });

    test('the table copied in block style is read — the stages stand below their channel', () {
      final List<CeilingStatement> found = read('''
channelStages:
  stable:
    - dev
    - test
    - prod
''');
      expect(found, hasLength(1));
      expect(found.single.channels, <String>{'stable'});
      expect(found.single.stages, <String>{'dev', 'test', 'prod'});
    });

    test('the block sequence at the KEY\'S OWN column is read — the second spelling of a list', () {
      final List<CeilingStatement> found = read('''
channelStages:
  alpha:
  - dev
  beta:
  - dev
  - test
''');
      expect(found, hasLength(2));
      expect(found.first.channels, <String>{'alpha'});
      expect(found.first.stages, <String>{'dev'});
      expect(found.last.channels, <String>{'beta'});
      expect(found.last.stages, <String>{'dev', 'test'});
    });

    test('the whole table on one line as a flow mapping is one statement naming every row', () {
      final List<CeilingStatement> found = read(
        'channelStages: {alpha: [dev], beta: [dev, test], stable: [dev, test, prod]}\n',
      );
      expect(found, hasLength(1));
      expect(found.single.channels, <String>{'alpha', 'beta', 'stable'});
      expect(found.single.stages, <String>{'dev', 'test', 'prod'});
    });

    test('a flow sequence broken over lines is read to its end', () {
      expect(
        read('''
  stable: [
    dev,
    test,
    prod,
  ]
''').single.stages,
        <String>{'dev', 'test', 'prod'},
      );
    });

    test('the table written the other way round is read — the stage is the key', () {
      final List<CeilingStatement> found = read('''
stageChannels:
  dev:
  - alpha
  - beta
  - stable
  prod:
  - stable
''');
      expect(found, hasLength(2));
      expect(found.first.stages, <String>{'dev'});
      expect(found.first.channels, <String>{'alpha', 'beta', 'stable'});
      expect(found.last.stages, <String>{'prod'});
      expect(found.last.channels, <String>{'stable'});
    });

    test('THE INNOCENT NEIGHBOUR: a same-column sequence under a key that is no channel', () {
      expect(
        read('''
stages:
- dev
- test
- prod
'''),
        isEmpty,
      );
    });

    test('THE INNOCENT NEIGHBOUR: a key naming a stage whose block names no channel', () {
      expect(
        read('''
dev:
  replicas: 1
'''),
        isEmpty,
      );
    });

    test('a shell case arm pairing a channel with its stages is read', () {
      final List<CeilingStatement> found = read(r'''
              case "${CHANNEL}" in
                alpha)  ALLOWED="dev" ;;
                beta)   ALLOWED="dev test" ;;
                stable) ALLOWED="dev test prod" ;;
              esac
''');
      expect(found, hasLength(3));
      expect(found.last.channels, <String>{'stable'});
      expect(found.last.stages, <String>{'dev', 'test', 'prod'});
    });

    test('a blank line does not end the block — a table spaced apart is the same table', () {
      expect(
        read('''
  beta:

    - dev
    - test
''').single.stages,
        <String>{'dev', 'test'},
      );
    });

    test('the block ends where the indentation returns', () {
      // The sibling key below is not part of the statement, and a reader that ran to the end of the
      // file would report every channel in it against every stage in it.
      final List<CeilingStatement> found = read('''
  alpha:
    - dev
  stage: prod
''');
      expect(found, hasLength(1));
      expect(found.single.stages, <String>{'dev'});
    });

    test('THE INNOCENT NEIGHBOUR: the tag grammar names every channel and no stage', () {
      // apps/consumer-build/templates/pipeline-release.yaml:159, the gate-stage line copied: the
      // channel is parsed OUT of the tag there, which names no stage and decides no ceiling.
      expect(
        read(
          r'''CHANNEL="$(printf '%s' "${TAG}" | sed -E 's/^[0-9]+\.[0-9]+\.[0-9]+-(alpha|beta|stable)-[0-9]{14}$/\1/')"''',
        ),
        isEmpty,
      );
    });

    test('THE INNOCENT NEIGHBOUR: the stage guard names every stage and no channel', () {
      expect(read(r'''case "${STAGE}" in dev|test|prod) ;; *)'''), isEmpty);
    });

    test('THE INNOCENT NEIGHBOUR: an apiVersion is not a channel', () {
      expect(
        read('''
apiVersion: argoproj.io/v1alpha1
kind: Application
spec:
  destination:
    namespace: dev
'''),
        isEmpty,
      );
    });

    test('THE INNOCENT NEIGHBOUR: a release tag in an image pin is not the ceiling', () {
      // The tag is apps/manager/values-dev.yaml:7 as it stands — the channel inside a pinned tag.
      // The stage sibling at the same indentation is added here, because that is the neighbour a
      // reader running past the line end would pair the tag with.
      expect(
        read('''
image:
  tag: "0.41.0-stable-20260818095821-beeae7f"
  stage: prod
'''),
        isEmpty,
      );
    });
  });

  group('what it refuses', () {
    const Set<String> channels = <String>{'alpha', 'beta', 'stable'};
    const Set<String> stages = <String>{'dev', 'test', 'prod'};
    const String table = '''
global:
  channelStages:
    alpha: [dev]
    beta: [dev, test]
    stable: [dev, test, prod]
''';

    test('the planted defect: a second file states the table, and every row is named', () {
      final List<SecondCeiling> found = auditChannelTableSingle(
        files: <String, String>{
          'platform/values-common.yaml': table,
          'platform/values-prod.yaml': table,
        },
        statedIn: 'platform/values-common.yaml',
        channels: channels,
        stages: stages,
      );

      expect(found, hasLength(3));
      expect(found.first.statement.where, 'platform/values-prod.yaml');
      expect(found.first.statement.line, 3);
      expect(found.first.toString(), contains('platform/values-prod.yaml:3'));
      expect(found.first.toString(), contains('"alpha"'));
      expect(found.first.toString(), contains('through the values chain as CHANNEL_STAGES'));
      expect(found.first.toString(), contains('off the trunk (readChannelStages'));
    });

    test('the planted defect: the second file states it in block-sequence style', () {
      final List<SecondCeiling> found = auditChannelTableSingle(
        files: <String, String>{
          'platform/values-common.yaml': table,
          'platform/values-prod.yaml': '''
global:
  channelStages:
    alpha:
    - dev
    beta:
    - dev
    - test
''',
        },
        statedIn: 'platform/values-common.yaml',
        channels: channels,
        stages: stages,
      );

      expect(found, hasLength(2));
      expect(found.first.statement.line, 3);
      expect(found.first.statement.text, 'alpha:');
      expect(found.first.statement.stages, <String>{'dev'});
      expect(found.last.statement.stages, <String>{'dev', 'test'});
    });

    test('the planted defect: the ceiling restated as a shell case arm in a template', () {
      final List<SecondCeiling> found = auditChannelTableSingle(
        files: <String, String>{
          'platform/values-common.yaml': table,
          'apps/consumer-build/templates/pipeline-release.yaml': r'''
            script: |
              #!/usr/bin/env sh
              case "${CHANNEL}" in
                stable) ALLOWED="dev test prod" ;;
              esac
''',
        },
        statedIn: 'platform/values-common.yaml',
        channels: channels,
        stages: stages,
      );

      expect(found, hasLength(1));
      expect(found.single.statement.where, 'apps/consumer-build/templates/pipeline-release.yaml');
      expect(found.single.statement.stages, <String>{'dev', 'test', 'prod'});
    });

    test('THE INNOCENT NEIGHBOUR: the one file that states it is not a second statement', () {
      expect(
        auditChannelTableSingle(
          files: <String, String>{
            'platform/values-common.yaml': table,
            'apps/consumer-build/templates/pipeline-release.yaml':
                '{{- \$channelStages := required "consumer-build: global.channelStages is required" '
                '.Values.global.channelStages -}}\n',
          },
          statedIn: 'platform/values-common.yaml',
          channels: channels,
          stages: stages,
        ),
        isEmpty,
      );
    });
  });
}

/// Every tracked text file of [repository] by the path a finding names, [except] the one directory
/// whose content is the checks themselves.
///
/// From git rather than from the file system, for the reason chart-paths reads it there: what a
/// cluster gets is a fresh clone, so an untracked file exists on this machine and nowhere else.
Map<String, String> _trackedTextOf(Directory repository, {required String except}) {
  final ProcessResult listed = Process.runSync(
    'git',
    <String>['ls-files'],
    workingDirectory: repository.path,
    runInShell: Platform.isWindows,
  );
  if (listed.exitCode != 0) {
    throw StateError('git ls-files failed: ${listed.stderr}');
  }
  return <String, String>{
    for (final String line in (listed.stdout as String).split('\n'))
      if (line.trim() case final String path)
        if (path.isNotEmpty && !path.startsWith('$except/'))
          path: File('${repository.path}/$path').readAsStringSync(),
  };
}

String _leafOf(String path) => path.split(RegExp(r'[\\/]')).last;
