import 'dart:io';

import 'package:hostyour_cloud_gate/hostyour_cloud_gate.dart';
import 'package:test/test.dart';

import 'support/repository_under_check.dart';

/// platform/versions.yaml is the one place a version of this platform is decided, and this reads
/// the decision back out of the tree.
///
/// The audit is [PinAudit]; this file drives it over the repository, where its findings must be
/// empty, and over trees planted for the purpose. What it does NOT do, and never will, is ask the
/// internet what upstream has now: a version appearing on the internet turning this tree red would
/// make red stop meaning "the tree is sound", and a gate whose red means two different things is a
/// gate people learn to ignore.
void main() {
  final Directory scratch = Directory.systemTemp.createTempSync('hostyour-pins-');
  final SourceTree tree = repositoryTree();
  final String? text = tree.textOf('platform/versions.yaml');
  final PinAudit audit = PinAudit(tree: tree, pins: VersionPins.parse(text ?? ''));

  tearDownAll(() => scratch.deleteSync(recursive: true));

  group('the repository', () {
    test('carries the pins at all', () {
      expect(text, isNotNull);
      expect(
        VersionPins.parse(text ?? '').components,
        isNotEmpty,
        reason: 'an empty file pins nothing and every assertion below would pass over it',
      );
    });

    test('states who reads every section of it', () {
      expect(audit.sectionsNobodyReads(), isEmpty);
    });

    test('decides every version it runs in that one file', () {
      final List<PinFinding> found = audit.versionsDecidedElsewhere();
      expect(found, isEmpty, reason: found.join('\n'));
    });

    test('runs one version of every image', () {
      final List<PinFinding> found = audit.imagesAtTwoVersions();
      expect(found, isEmpty, reason: found.join('\n'));
    });

    test('resolves every in-tree component, for both roles and at every stage', () {
      final List<PinFinding> found = audit.componentsWithoutAReader();
      expect(found, isEmpty, reason: found.join('\n'));
    });
  });

  group('a version is read out of its position and never out of the text', () {
    // Two shapes carry an upstream version, and a third looks like one and is not. Telling them
    // apart by position is what makes this measurable without an exemption list: an upstream image
    // names the registry it is pulled from, and one this repository builds names only the build it
    // comes out of.

    late List<VersionReader> readers;

    setUpAll(() {
      readers = versionReadersIn(
        SourceTree.planted(
          Directory('${scratch.path}${Platform.pathSeparator}readers')..createSync(recursive: true),
          <String, String>{
            'apps/probe/Chart.yaml': '''
apiVersion: v2
name: probe
dependencies:
  - name: upstream
    version: 1.2.3
    repository: https://charts.example.com
  - name: library
    version: 1.0.0
    repository: file://../../charts/library
''',
            'apps/probe/values-common.yaml': '''
app:
  image:
    repository: ghcr.io/example/upstream
    tag: "4.5.6"
builds:
  - name: ours
    image: ours
    tag: "0.0.0"
''',
          },
        ),
      );
    });

    test('a dependency fetched from a chart repository is one', () {
      expect(
        readers
            .where((VersionReader r) => r.kind == VersionReaderKind.chartDependency)
            .map((VersionReader r) => '${r.component}@${r.version}'),
        <String>['upstream@1.2.3'],
        reason:
            'a file:// dependency is a library chart of this repository, versioned with the '
            'repository itself and decided nowhere else',
      );
    });

    test('an image block naming the registry it is pulled from is one', () {
      expect(
        readers
            .where((VersionReader r) => r.kind == VersionReaderKind.upstreamImage)
            .map((VersionReader r) => '${r.component}@${r.version}'),
        <String>['ghcr.io/example/upstream@4.5.6'],
      );
    });

    test('an image this repository builds is not', () {
      expect(
        readers.map((VersionReader r) => r.version),
        isNot(contains('0.0.0')),
        reason:
            'builds[]{name,image,tag} is the grammar a release bump writes into, and versions.yaml '
            'has nothing to say about a tag this platform mints for itself',
      );
    });
  });

  group('counter-probe', () {
    late Directory probeRoot;

    setUp(() {
      probeRoot = Directory.systemTemp.createTempSync('hostyour-pins-probe-');
    });
    tearDown(() => probeRoot.deleteSync(recursive: true));

    PinAudit auditOf(String pins, Map<String, String> files) =>
        PinAudit(tree: SourceTree.planted(probeRoot, files), pins: VersionPins.parse(pins));

    test('a version written in the tree that no pin carries is reported', () {
      expect(
        auditOf('images:\n  something: "1.0.0"\n', <String, String>{
          'apps/probe/values-common.yaml':
              'app:\n  image:\n    repository: ghcr.io/example/x\n    tag: "9.9.9"\n',
        }).versionsDecidedElsewhere(),
        contains(
          isA<VersionDecidedElsewhere>().having(
            (VersionDecidedElsewhere f) => f.version,
            'version',
            '9.9.9',
          ),
        ),
      );
    });

    test('one image at two versions is reported', () {
      expect(
        auditOf('images:\n  x: "1.0.0"\n  y: "2.0.0"\n', <String, String>{
          'apps/one/values-common.yaml':
              'app:\n  image:\n    repository: ghcr.io/example/x\n    tag: "1.0.0"\n',
          'apps/two/values-common.yaml':
              'app:\n  image:\n    repository: ghcr.io/example/x\n    tag: "2.0.0"\n',
        }).imagesAtTwoVersions(),
        contains(
          isA<ImageAtTwoVersions>().having(
            (ImageAtTwoVersions f) => f.versions,
            'versions',
            <String>['1.0.0', '2.0.0'],
          ),
        ),
      );
    });

    test('a component nothing reads is reported', () {
      expect(
        auditOf('images:\n  orphan: "3.3.3"\n', <String, String>{
          'apps/probe/values-common.yaml': 'app: {}\n',
        }).componentsWithoutAReader(),
        contains(
          isA<ComponentWithoutAReader>().having(
            (ComponentWithoutAReader f) => f.coordinate,
            'coordinate',
            'images.orphan',
          ),
        ),
      );
    });

    test('a component only one stage reads is reported for the other two', () {
      final List<PinFinding> found = auditOf('images:\n  onlyprod: "5.5.5"\n', <String, String>{
        'apps/probe/values-prod.yaml':
            'app:\n  image:\n    repository: ghcr.io/example/x\n    tag: "5.5.5"\n',
      }).componentsWithoutAReader();
      expect(
        found.whereType<ComponentWithoutAReader>().map((ComponentWithoutAReader f) => f.stage),
        containsAll(<String>['dev', 'test']),
        reason:
            'the role stamp removes the other two stages\' per-app overrides, so a component whose '
            'only reader stands in one of them produces a branch with a hole in it, and the hole '
            'is found on the machine',
      );
      expect(
        found.whereType<ComponentWithoutAReader>().map((ComponentWithoutAReader f) => f.stage),
        isNot(contains('prod')),
      );
    });

    test('a section nothing states a reader for is reported', () {
      expect(
        auditOf('surprise:\n  x: "1"\n', const <String, String>{}).sectionsNobodyReads(),
        contains(
          isA<SectionNobodyReads>().having(
            (SectionNobodyReads f) => f.section,
            'section',
            'surprise',
          ),
        ),
      );
    });

    test('a section that vanished is reported', () {
      expect(
        auditOf('images:\n  x: "1"\n', const <String, String>{}).sectionsNobodyReads(),
        contains(isA<SectionVanished>()),
      );
    });
  });
}
