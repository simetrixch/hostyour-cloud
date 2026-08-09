import 'dart:io';

import 'package:hostyour_cloud_gate/hostyour_cloud_gate.dart';
import 'package:test/test.dart';

import 'support/repository_under_check.dart';

/// The abolished words stand in no name of this repository.
///
/// The audit is [NamingAudit]; this file drives it over the repository, where its findings must be
/// empty, and over a tree planted for the purpose that carries a violation of every rule AND the
/// correct neighbour of each — so a scan that reported everything is caught as surely as one that
/// reports nothing.
///
/// The neighbours are the point. `tools/lib/src/installation.dart` is a real file of this package,
/// and a check that collapsed back into a match on the substring would demand it be renamed to
/// something that no longer says what it is.
void main() {
  final Directory scratch = Directory.systemTemp.createTempSync('hostyour-naming-');
  final SourceTree tree = repositoryTree();
  final NamingAudit audit = NamingAudit(tree);

  tearDownAll(() => scratch.deleteSync(recursive: true));

  group('the repository', () {
    test('has names to judge', () {
      expect(tree.paths, isNotEmpty, reason: 'nothing was walked, so this check measured nothing');
    });

    test('carries an abolished word in no file name and in no directory name', () {
      final List<NamingFinding> found = audit.findings();
      expect(found, isEmpty, reason: found.join('\n'));
    });

    test('keeps the product\'s own word for one deployment of itself', () {
      expect(
        tree.holds('tools/lib/src/installation.dart'),
        isTrue,
        reason:
            'the neighbour the rule exists to protect; if it is renamed or gone, the counter-probe '
            'below is guarding a case this tree no longer has',
      );
    });
  });

  group('the rule is about a word and not about a substring', () {
    test('the abolished program name is refused wherever the name sits', () {
      expect(AbolishedWord.install.isIn('install.dart'), isTrue);
      expect(AbolishedWord.install.isIn('install-cluster.yaml'), isTrue);
      expect(AbolishedWord.setup.isIn('setup'), isTrue);
      expect(AbolishedWord.setup.isIn('pre-setup-job.yaml'), isTrue);
    });

    test('a longer word that merely begins with it is not', () {
      expect(AbolishedWord.install.isIn('installation.dart'), isFalse);
      expect(AbolishedWord.install.isIn('installation_values.dart'), isFalse);
      expect(AbolishedWord.setup.isIn('setups.yaml'), isFalse);
    });

    test('the same word wearing a capital is still the word', () {
      expect(AbolishedWord.install.isIn('Install.dart'), isTrue);
      expect(AbolishedWord.setup.isIn('SETUP-cluster.yaml'), isTrue);
    });

    test('desktop is refused wherever it sits inside a name', () {
      expect(AbolishedWord.desktop.isIn('desktop.dart'), isTrue);
      expect(AbolishedWord.desktop.isIn('mydesktopthing.yaml'), isTrue);
    });
  });

  group('counter-probe', () {
    late List<NamingFinding> found;

    setUpAll(() {
      found = NamingAudit(
        SourceTree.planted(
          Directory('${scratch.path}${Platform.pathSeparator}probe')..createSync(recursive: true),
          <String, String>{
            'setup/whatever.yaml': 'a: b',
            'apps/desktop/values.yaml': 'a: b',
            'install.dart': 'const int x = 1;',
            'apps/probe/templates/setup-cluster.yaml': 'a: b',
            'tools/lib/src/installation.dart': 'const int x = 2;',
            'tools/lib/src/render/installation_values.dart': 'const int x = 3;',
            'apps/registry/values-prod.yaml': 'a: b',
          },
        ),
      ).findings();
    });

    Iterable<AbolishedWordInAName> named(String segment) => found
        .whereType<AbolishedWordInAName>()
        .where((AbolishedWordInAName f) => f.segment == segment);

    for (final String segment in <String>[
      'setup',
      'desktop',
      'install.dart',
      'setup-cluster.yaml',
    ]) {
      test('the planted name "$segment" is reported', () {
        expect(named(segment), isNotEmpty, reason: 'the name scan cannot go red');
      });
    }

    for (final String segment in <String>[
      'installation.dart',
      'installation_values.dart',
      'values-prod.yaml',
    ]) {
      test('"$segment" says what it is and is not reported', () {
        expect(
          named(segment),
          isEmpty,
          reason: 'the name scan has collapsed back into a match on the substring',
        );
      });
    }

    test('a directory is reported once however many files stand under it', () {
      expect(named('setup'), hasLength(1));
    });

    test('a tree with no paths is reported as measuring nothing', () {
      final Directory bare = Directory('${scratch.path}${Platform.pathSeparator}bare')
        ..createSync(recursive: true);
      expect(NamingAudit(SourceTree.planted(bare, const <String, String>{})).findings(), <Matcher>[
        isA<NothingWasNamed>(),
      ]);
    });
  });
}
