import 'dart:io';

import 'package:test/test.dart';

import '../tool/toolchain_guard.dart';

/// The toolchain guard, driven with scripted versions.
///
/// The guard is what the pin IS now that no container installs it: the gate refuses to run on any
/// Dart or any helm but the pinned ones, so a green run means green against one toolchain. Both
/// directions are probed for each tool — a guard that never refuses is no pin, and one that refuses
/// the pinned toolchain stops every run there is — and both parses are held against what this very
/// machine answers, for the day either output changes shape.
void main() {
  const String pinnedDart = '3.12.2';
  const String pinnedHelm = 'v4.2.3';
  const String theRightDart = '3.12.2 (stable) (Tue Jun 9 01:11:39 2026 -0700) on "windows_x64"';
  const String anotherDart = '3.13.0 (stable) (Mon Sep 7 10:00:00 2026 +0000) on "linux_x64"';

  String? refusalOn({String dart = theRightDart, String helm = pinnedHelm}) => toolchainRefusal(
    runningDart: dart,
    pinnedDart: pinnedDart,
    helmSaid: helm,
    pinnedHelm: pinnedHelm,
  );

  group('Dart', () {
    test('the pinned SDK passes', () {
      expect(
        refusalOn(),
        isNull,
        reason: 'a guard that refuses the pinned toolchain stops every run there is',
      );
    });

    test('any other SDK is refused', () {
      expect(
        refusalOn(dart: anotherDart),
        isNotNull,
        reason: 'a guard that never refuses is no pin at all',
      );
    });

    test('the refusal names what was found and what was expected', () {
      final String? refusal = refusalOn(dart: anotherDart);
      expect(refusal, contains('3.13.0'));
      expect(
        refusal,
        contains(pinnedDart),
        reason: 'a refusal naming only one of the two versions leaves the fix to a guess',
      );
    });

    test('the version is read out of the shape Platform.version answers', () {
      expect(dartVersionOf(theRightDart), pinnedDart);
    });

    test('what the guard reads out of this very SDK is a bare semantic version', () {
      expect(
        dartVersionOf(Platform.version),
        matches(RegExp(r'^\d+\.\d+\.\d+')),
        reason:
            'the parse takes everything before the first whitespace; if Platform.version ever '
            'changed shape, the guard would refuse every SDK including the pinned one',
      );
    });
  });

  group('helm', () {
    test('any other helm is refused, naming both versions', () {
      final String? refusal = refusalOn(helm: 'v4.3.0');
      expect(refusal, contains('v4.3.0'));
      expect(refusal, contains(pinnedHelm));
    });

    test('no helm at all is refused rather than passed over', () {
      expect(
        refusalOn(helm: ''),
        isNotNull,
        reason:
            'a machine without helm renders no chart, and a run that treated that as a pass would '
            'report a tree it never opened',
      );
    });

    test('an error helm wrote where a version was asked for is not read as one', () {
      expect(helmVersionIn('Error: unknown flag: --template'), isNull);
    });

    test('what helm on this machine writes is a version this guard can read', () {
      expect(
        helmVersionIn(whatHelmSaysItIs()),
        isNotNull,
        reason:
            'the render audit starts the same helm, so a machine that cannot answer this cannot '
            'run the gate either; if the output ever changes shape, the guard would refuse every '
            'helm including the pinned one',
      );
    });
  });
}
