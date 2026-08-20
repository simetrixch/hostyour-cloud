import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';

/// release-pin-tags — over the real trees, and over planted ones.
///
/// **What this is guarding.** A `builds[]` entry states which image a stage runs, and apart from the
/// one value named below nothing on either side of the repository boundary refuses a tag no release
/// ever minted: the chart renders whatever string stands there into an image ref, the release bump
/// only overwrites an entry it already finds, and the Controller's pin schema types the tag as a
/// non-empty string. A stage no release has reached therefore keeps the string a person typed, and
/// the first thing that says so is a pull failure on a cluster.
///
/// **The one value that is not a release tag.** An entry has to stand in the file before the release
/// that writes its tag, so a stage no release has reached carries the placeholder
/// `platform/values-common.yaml` states under `global.placeholderTag`, and this check admits it.
/// `charts/common` `common.buildTag` refuses to render it, so the value deploys nothing while it
/// stands. The last group drives `pinnedTagsIn` and `auditPinTags` over the pin file of one planted
/// application: the tag it is added with, the tag the first release leaves behind, and what is
/// refused in between. That is the reach of this suite — the render half (`charts/common`
/// `common.buildTag`) and the bump half (`apps/consumer-build` `pipeline-release.yaml` `bump_file`)
/// are the other two readers of the same value and neither is executed anywhere here.
///
/// **Why nothing here restates the grammar.** A pattern written into this suite would be a second
/// spelling of the release grammar, and the drift being watched for could then happen inside the
/// guard. Both halves are read out of the Controller tree, where they are decided, and the
/// placeholder out of the values file both readers of it take it from.
void main() {
  final Directory repository = Directory.current.parent;

  group('the trees as they stand', () {
    test('every pinned tag in this tree is a tag a release minted', () {
      final Directory controller = controllerRoot();
      final RegExp? releaseTag = releaseTagPatternIn(
        File('${controller.path}/$controllerReleaseGrammar').readAsStringSync(),
      );
      final RegExp? imageTag = imageSuffixPatternIn(
        File('${controller.path}/$controllerImageSuffix').readAsStringSync(),
      );

      // A comparison against nothing reads like a pass, which is the failure this suite exists to
      // refuse. Every side is asserted present before anything is judged against it.
      expect(
        releaseTag,
        isNotNull,
        reason:
            'the Controller\'s $controllerReleaseGrammar states no $releaseTagConstant — '
            'it was not read',
      );
      expect(
        imageTag,
        isNotNull,
        reason:
            'the Controller\'s $controllerImageSuffix states no $imageSuffixConstant — '
            'it was not read',
      );
      final String? placeholder = _statedPlaceholderIn(repository);
      expect(
        placeholder,
        isNotNull,
        reason:
            'this tree\'s $platformValues states no global.$placeholderTagKey — the value the '
            'chart refuses and this check admits was not read, and the two cannot agree on a '
            'string neither of them has',
      );

      final Map<String, List<PinnedTag>> pins = _pinsOf(repository);
      expect(
        pins,
        isNotEmpty,
        reason: 'no tracked file of this tree states pins — nothing was read',
      );

      expect(
        auditPinTags(
          pins: pins,
          releaseTag: releaseTag!,
          imageTag: imageTag!,
          placeholder: placeholder!,
        ).map((OffGrammarPin each) => each.toString()),
        isEmpty,
      );
    });

    test('HOW MUCH IT COVERS: against a grammar nothing matches, every pin of this tree reports', () {
      // What this measures is not the grammar but the REACH: a pin the reader passed over would be
      // silent here too, and a check that judges half a tree reads exactly like one that judges all
      // of it and found nothing.
      final Map<String, List<PinnedTag>> pins = _pinsOf(repository);
      final int stated = pins.values.fold(0, (int sum, List<PinnedTag> each) => sum + each.length);
      expect(stated, greaterThan(0), reason: 'a check over nothing reads like a pass');

      expect(
        auditPinTags(
          pins: pins,
          releaseTag: _never,
          imageTag: _never,
          placeholder: _noPinCarriesThis,
        ),
        hasLength(stated),
      );
    });
  });

  group('what it reads', () {
    test('the grammar is read out of the Controller\'s own constant, across the line break', () {
      expect(
        releaseTagPatternIn('export const $releaseTagConstant =\n  /^[0-9]+-(a|b)\$/;\n')?.pattern,
        r'^[0-9]+-(a|b)$',
      );
    });

    test('a delimiter inside a character class does not end the literal', () {
      expect(declaredPatternIn('const X = /[a/b]+\$/;', 'X')?.pattern, r'[a/b]+$');
    });

    test('an escaped delimiter does not end the literal', () {
      expect(declaredPatternIn(r'const X = /a\/b/;', 'X')?.pattern, r'a\/b');
    });

    test('a source stating no such constant reads as absent, never as an empty grammar', () {
      expect(releaseTagPatternIn('export const SOMETHING_ELSE = /x/;'), isNull);
      expect(imageSuffixPatternIn('// $imageSuffixConstant is only mentioned here'), isNull);
    });

    test('a name mentioned in prose before it is declared is passed over', () {
      expect(
        declaredPatternIn('// the build plane carries a copy of X —\nconst X = /y/;', 'X')?.pattern,
        'y',
      );
    });

    test('a file with no builds key states no pins, and is never parsed for them', () {
      expect(statesPins('replicas: 1\nimage: {{ .Values.thing }}\n'), isFalse);
    });

    test('the pins are read out of the builds list, in the order the file states them', () {
      expect(
        pinnedTagsIn('planted', _carrier(<String, String>{'manager': '1.2.3', 'dbtools': '4.5.6'})),
        <PinnedTag>[
          (name: 'manager', image: 'manager', tag: '1.2.3'),
          (name: 'dbtools', image: 'dbtools', tag: '4.5.6'),
        ],
      );
    });

    test('the placeholder is read out of this tree\'s own values file', () {
      expect(placeholderTagIn('global:\n  $placeholderTagKey: "0.0.0-planted"\n'), '0.0.0-planted');
    });

    test('a values file stating no placeholder reads as absent, never as an empty admission', () {
      expect(placeholderTagIn('global:\n  timezone: Europe/Amsterdam\n'), isNull);
      expect(placeholderTagIn('$placeholderTagKey: "0.0.0-planted"\n'), isNull);
      expect(placeholderTagIn('# ${placeholderTagKey}s are discussed here\n'), isNull);
    });

    test('a builds that is no list is a refusal naming the file, never an empty answer', () {
      expect(
        () => pinnedTagsIn('planted', 'builds: yes\n'),
        throwsA(
          isA<StateError>().having((StateError e) => e.message, 'message', contains('planted')),
        ),
      );
    });

    test('an entry with no tag is a refusal naming the entry, never an empty answer', () {
      expect(
        () => pinnedTagsIn('planted', 'builds:\n  - name: manager\n    image: manager\n'),
        throwsA(
          isA<StateError>().having((StateError e) => e.message, 'message', contains('"manager"')),
        ),
      );
    });

    test('an entry with no image is a refusal — no release bump ever writes that one', () {
      expect(
        () => pinnedTagsIn('planted', 'builds:\n  - name: manager\n    tag: "0.0.0"\n'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            allOf(contains('"manager"'), contains('by its image')),
          ),
        ),
      );
    });
  });

  group('what it reports', () {
    final RegExp releaseTag = releaseTagPatternIn(
      File('${controllerRoot().path}/$controllerReleaseGrammar').readAsStringSync(),
    )!;
    final RegExp imageTag = imageSuffixPatternIn(
      File('${controllerRoot().path}/$controllerImageSuffix').readAsStringSync(),
    )!;

    final String placeholder = _placeholderOf(Directory.current.parent);

    List<OffGrammarPin> judge(String tag) => auditPinTags(
      pins: <String, List<PinnedTag>>{
        'planted': <PinnedTag>[(name: 'manager', image: 'manager', tag: tag)],
      },
      releaseTag: releaseTag,
      imageTag: imageTag,
      placeholder: placeholder,
    );

    test('THE PLANTED DEFECT: the version a first pin reaches for, which names no release', () {
      expect(judge('0.0.0').single.toString(), contains('"0.0.0"'));
    });

    test('THE PLANTED DEFECT: the placeholder with anything appended to it', () {
      expect(judge('$placeholder-1'), hasLength(1));
    });

    test('a refusal names the placeholder, so it says what to write instead', () {
      expect(judge('0.0.0').single.toString(), contains(placeholder));
    });

    test('THE PLANTED DEFECT: a bare version, with no channel and no stamp', () {
      expect(judge('0.41.0'), hasLength(1));
    });

    test('THE PLANTED DEFECT: a mutable tag naming a branch rather than a release', () {
      expect(judge('latest'), hasLength(1));
    });

    test('THE PLANTED DEFECT: a version with leading zeros, which aliases another release', () {
      expect(judge('01.02.03-stable-20260818095821-beeae7f'), hasLength(1));
    });

    test('THE PLANTED DEFECT: a channel the release grammar does not name', () {
      expect(judge('0.41.0-nightly-20260818095821-beeae7f'), hasLength(1));
    });

    test('THE PLANTED INNOCENT: the image tag a release pipeline pushes', () {
      expect(judge('0.41.0-stable-20260818095821-beeae7f'), isEmpty);
    });

    test('THE PLANTED INNOCENT: the bare release tag, without the image suffix', () {
      expect(judge('0.41.0-stable-20260818095821'), isEmpty);
    });

    test('a report names the file, the entry and the tag, so it says where to go', () {
      final OffGrammarPin found = judge('0.0.0').single;
      expect(found.where, 'planted');
      expect(found.name, 'manager');
      expect(found.tag, '0.0.0');
      expect(found.toString(), contains(releaseTag.pattern));
    });
  });

  group(
    'THE COUNTER-PROBE: an application added to this tree, before and after its first release',
    () {
      // hostyour-cloud#63's admission rule, driven over ONE planted carrier: the entry a person
      // writes when they add `apps/<app>/`, the same entry after the release bump has written the
      // minted tag into the one it found by `image`, and the values that are still refused in
      // between. What runs is `pinnedTagsIn` and `auditPinTags` over the string `_carrier` builds —
      // no file is written, no chart is rendered and the bump task is not executed. The "after" half
      // carries the same minted tag the tree's own pins carry, so a release grammar that stopped
      // matching it turns this probe red.
      final RegExp releaseTag = releaseTagPatternIn(
        File('${controllerRoot().path}/$controllerReleaseGrammar').readAsStringSync(),
      )!;
      final RegExp imageTag = imageSuffixPatternIn(
        File('${controllerRoot().path}/$controllerImageSuffix').readAsStringSync(),
      )!;
      final String placeholder = _placeholderOf(Directory.current.parent);

      List<OffGrammarPin> judgeNewApp(String tag) => auditPinTags(
        pins: <String, List<PinnedTag>>{
          'apps/planted/values-dev.yaml': pinnedTagsIn(
            'apps/planted/values-dev.yaml',
            _carrier(<String, String>{'planted': tag}),
          ),
        },
        releaseTag: releaseTag,
        imageTag: imageTag,
        placeholder: placeholder,
      );

      test('BEFORE ANY RELEASE: the placeholder pin a new application is added with passes', () {
        expect(judgeNewApp(placeholder), isEmpty);
      });

      test(
        'AFTER THE FIRST RELEASE: the same application carrying the minted image tag passes',
        () {
          expect(judgeNewApp('0.41.0-stable-20260818095821-beeae7f'), isEmpty);
        },
      );

      test('IN BETWEEN: every other value a first pin could reach for is still refused', () {
        for (final String tag in <String>['0.0.0', '0.1.0', 'latest', 'placeholder', 'dev']) {
          expect(judgeNewApp(tag), hasLength(1), reason: '$tag was admitted');
        }
      });
    },
  );
}

/// A pattern that matches nothing, so a probe measures the reach and not a grammar.
final RegExp _never = RegExp(r'(?!)');

/// A placeholder no pin can carry, so the reach probe measures the reach and not the admission.
///
/// The empty string: the chart's `common.buildTag` `required`s the key and the Controller's own pin
/// schema types it `min(1)`, so no carrier of this tree can state it.
const String _noPinCarriesThis = '';

/// The tag [repository] states that a stage carries before its first release, or null where its
/// values file states none.
String? _statedPlaceholderIn(Directory repository) =>
    placeholderTagIn(File('${repository.path}/$platformValues').readAsStringSync());

/// The same value, refused BY NAME where the file states none.
///
/// A group that judges tags needs it while it is being DECLARED, where no expectation can run and a
/// bare null check reports that a null was used and names neither the file nor the key.
String _placeholderOf(Directory repository) =>
    _statedPlaceholderIn(repository) ??
    (throw StateError(
      '$platformValues states no global.$placeholderTagKey — the value charts/common '
      'common.buildTag refuses and this check admits cannot be read, so neither side has a string '
      'to agree on.',
    ));

/// A planted carrier stating one `builds[]` entry per name/tag pair.
String _carrier(Map<String, String> pins) => <String>[
  'builds:',
  for (final MapEntry<String, String> each in pins.entries)
    '  - name: ${each.key}\n    image: ${each.key}\n    tag: "${each.value}"',
].join('\n');

/// The pins of every tracked file of [repository] that states any, keyed by the file.
///
/// Tracked and not on-disk, for the reason the paths of this tree are judged against git: what a
/// cluster reads is a fresh clone, so an untracked carrier is one that exists here and nowhere else.
Map<String, List<PinnedTag>> _pinsOf(Directory repository) {
  final ProcessResult listed = Process.runSync('git', <String>[
    'ls-files',
  ], workingDirectory: repository.path);
  if (listed.exitCode != 0) {
    throw StateError('git ls-files failed in ${repository.path}: ${listed.stderr}');
  }
  final Map<String, List<PinnedTag>> pins = <String, List<PinnedTag>>{};
  for (final String path in (listed.stdout as String).split('\n')) {
    final String each = path.trim();
    if (!each.endsWith('.yaml') && !each.endsWith('.yml')) {
      continue;
    }
    final String text = File('${repository.path}/$each').readAsStringSync();
    if (statesPins(text)) {
      pins[each] = pinnedTagsIn(each, text);
    }
  }
  return pins;
}
