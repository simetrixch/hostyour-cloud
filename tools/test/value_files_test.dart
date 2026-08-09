import 'dart:io';

import 'package:hostyour_cloud_gate/hostyour_cloud_gate.dart';
import 'package:test/test.dart';

import 'support/repository_under_check.dart';

/// Every product values file the generators of this repository name is here.
///
/// The audit is [ValueFilesAudit]; this file drives it over the repository, where its findings must
/// be empty, and over a tree planted for the purpose that carries one instance of every defect it is
/// supposed to find, each beside a correct neighbour.
///
/// It also asserts the LINE the audit draws, because that line is the whole of what it decides. The
/// platform files and each catalog app's own two are required; one installation's own files are not;
/// and the files the tenant and consumer generators name in ANOTHER repository are placed there and
/// left alone — a check that quietly demanded those would be red on a repository that is not the
/// gate's to judge, and one that quietly dropped the first kind would be green on a tree missing
/// them.
void main() {
  final SourceTree tree = repositoryTree();
  final ValueFilesAudit audit = ValueFilesAudit(
    tree: tree,
    declaration: ClassDeclaration.parse(tree.textOf(declarationFile) ?? ''),
  );

  group('the repository', () {
    test('reads every ApplicationSet it carries', () {
      expect(
        audit.manifests().map((GeneratorManifest each) => each.path),
        containsAll(<String>[
          'apps/consumer-build/files/applicationset.yaml',
          for (final String stage in stages) ...<String>[
            'argocd/$stage/apps/applicationset.yaml',
            'argocd/$stage/apps/consumers-appset.yaml',
            'argocd/$stage/apps/slaves-appset.yaml',
            'argocd/$stage/apps/tenants-appset.yaml',
          ],
        ]),
        reason:
            'the four generators of every stage plus the build fan-out; a generator that is not '
            'read is one whose values files nothing decides about',
      );
    });

    test('names values files in every one of them that has a list', () {
      expect(audit.generatorsThatWereNotRead(), isEmpty);
    });

    test('places every entry every generator names', () {
      final List<ValueFilesFinding> found = audit.filesThatCannotBePlaced();
      expect(found, isEmpty, reason: found.join('\n'));
    });

    test('carries every product values file its generators name', () {
      final List<ValueFilesFinding> found = audit.productFilesThatAreGone();
      expect(found, isEmpty, reason: found.join('\n'));
    });

    test('requires the platform files and each catalog app\'s own two', () {
      expect(
        audit.requiredPaths(),
        containsAll(<String>[
          'platform/values-common.yaml',
          for (final String stage in stages) 'platform/values-$stage.yaml',
          'apps/manager/values-common.yaml',
          for (final String stage in stages) 'apps/manager/values-$stage.yaml',
          'apps/consumer-build/values-common.yaml',
          'apps/slave/values-common.yaml',
          for (final String stage in stages) 'apps/slave/values-$stage.yaml',
        ]),
        reason:
            'the platform catalog names `values-common.yaml` and `values-<stage>.yaml` under '
            '`apps/{{ .name }}`, so every name its list carries owes four files; the slave and the '
            'build fan-out name theirs as literal paths',
      );
    });

    test('requires nothing that belongs to one installation', () {
      expect(
        audit.requiredPaths().where((String path) => path.startsWith('cluster/')),
        isEmpty,
        reason:
            'cluster/profile.yaml and cluster/values/<app>.yaml are what an installation supplies; '
            'branch-classes.yaml calls them install, and the flag exists so their absence renders',
      );
    });

    test('leaves the tenant generator\'s member files in the catalog', () {
      final List<NamedValueFile> members = _entriesOf(
        audit,
        'argocd/prod/apps/tenants-appset.yaml',
      ).where((NamedValueFile each) => each.entry == 'values.yaml').toList(growable: false);

      expect(members, isNotEmpty);
      expect(
        members.map((NamedValueFile each) => each.standing),
        everyElement(
          isA<InAnotherRepository>().having(
            (InAnotherRepository each) => each.repository,
            'repository',
            '__CATALOG_REPO__',
          ),
        ),
        reason:
            'a member chart and its own values files stand on the tenant catalog\'s trunk, which '
            'this gate does not read; requiring them here would be a check that is green because '
            'it looked at nothing',
      );
    });

    test('leaves the tenant generator\'s pins file in the catalog', () {
      final Iterable<NamedValueFile> pins = _entriesOf(
        audit,
        'argocd/prod/apps/tenants-appset.yaml',
      ).where((NamedValueFile each) => each.entry.startsWith(r'$pins/'));

      expect(pins, isNotEmpty);
      expect(
        pins.map((NamedValueFile each) => each.standing),
        everyElement(
          isA<InAnotherRepository>().having(
            (InAnotherRepository each) => each.repository,
            'repository',
            '__CATALOG_REPO__',
          ),
        ),
        reason:
            'the pin is written by this installation\'s own release bump onto the catalog\'s books '
            'branch, and it is the one file the flag is set for',
      );
    });

    test('leaves a preset selected by a registration unplaced rather than guessed', () {
      final Iterable<NamedValueFile> presets = _entriesOf(
        audit,
        'argocd/prod/apps/consumers-appset.yaml',
      ).where((NamedValueFile each) => each.entry.startsWith('values-size-'));

      expect(presets, isNotEmpty);
      expect(
        presets.map((NamedValueFile each) => each.standing),
        everyElement(
          isA<NamedByAGeneratorParameter>().having(
            (NamedByAGeneratorParameter each) => each.expression,
            'expression',
            '{{ .size }}',
          ),
        ),
        reason:
            'which preset a unit gets is `{{ .size }}`, resolved by the manager out of a size table '
            'in its own database; this tree cannot enumerate that vocabulary, and a check that '
            'guessed it would require files nobody named',
      );
    });
  });

  group('counter-probe', () {
    late Directory probeRoot;
    late SourceTree probe;

    setUp(() {
      probeRoot = Directory.systemTemp.createTempSync('hostyour-values-probe-');
      probe = _plantedRepository(probeRoot);
    });
    tearDown(() => probeRoot.deleteSync(recursive: true));

    ValueFilesAudit auditOf(SourceTree planted) => ValueFilesAudit(
      tree: planted,
      declaration: ClassDeclaration.parse(planted.textOf(declarationFile) ?? ''),
    );

    test('a product values file the generator names and the tree lacks is reported', () {
      expect(
        auditOf(probe).productFilesThatAreGone(),
        contains(
          isA<ProductValuesFileIsGone>()
              .having((ProductValuesFileIsGone f) => f.path, 'path', 'apps/gone/values-common.yaml')
              .having(
                (ProductValuesFileIsGone f) => f.manifest,
                'manifest',
                'argocd/dev/apps/applicationset.yaml',
              ),
        ),
        reason:
            'the planted catalog names `gone` beside `present`, and the two differ only in whether '
            'the file behind `values-common.yaml` is there',
      );
    });

    test('the same file under the name that IS there is not reported', () {
      expect(
        auditOf(probe).productFilesThatAreGone().map((ValueFilesFinding f) => f.describe()),
        everyElement(isNot(contains('apps/present/values-common.yaml'))),
        reason:
            'a check that reported the correct neighbour too would be red for everything and would '
            'say nothing about either',
      );
    });

    test('an entry reading through a ref no source declares is reported', () {
      expect(
        auditOf(probe).filesThatCannotBePlaced(),
        contains(
          isA<ValueFileCannotBePlaced>().having(
            (ValueFileCannotBePlaced f) => f.entry,
            'entry',
            r'$absent/platform/values-common.yaml',
          ),
        ),
      );
    });

    test('an entry relative to a source that names no chart path is reported', () {
      expect(
        auditOf(probe).filesThatCannotBePlaced(),
        contains(
          isA<ValueFileCannotBePlaced>()
              .having((ValueFileCannotBePlaced f) => f.entry, 'entry', 'values-common.yaml')
              .having((ValueFileCannotBePlaced f) => f.why, 'why', contains('no chart path')),
        ),
      );
    });

    test('a list written in a shape the reader cannot follow is reported', () {
      expect(
        auditOf(probe).generatorsThatWereNotRead(),
        contains(
          isA<ValueFilesWereNotRead>().having(
            (ValueFilesWereNotRead f) => f.manifest,
            'manifest',
            'argocd/dev/apps/slaves-appset.yaml',
          ),
        ),
        reason:
            'the planted generator writes its list as a flow sequence on one line; the reader does '
            'not follow that, and the point is that it says so instead of measuring nothing',
      );
    });

    test('a product values file withheld from THIS repository is reported', () {
      // The planted trees above prove the audit reads what it is given. This one proves it about
      // the tree it is actually pointed at: the real manifests, the real declaration, and one real
      // file taken out of what git tracks — which is the whole of what going missing means here.
      const String withheld = 'apps/dbgate/values-dev.yaml';
      final Directory root = repositoryRoot();
      expect(tree.holds(withheld), isTrue, reason: 'nothing was withheld, so nothing was proven');

      final SourceTree without = SourceTree.readingFrom(
        root,
        trackedPathsIn(root).where((String path) => path != withheld).toList(growable: false),
      );
      expect(
        auditOf(without).productFilesThatAreGone(),
        contains(
          isA<ProductValuesFileIsGone>()
              .having((ProductValuesFileIsGone f) => f.path, 'path', withheld)
              .having((ProductValuesFileIsGone f) => f.entry, 'entry', 'values-dev.yaml'),
        ),
      );
    });

    test('a tree whose generators name nothing is reported', () {
      final SourceTree empty = SourceTree.planted(
        Directory('${probeRoot.path}${Platform.pathSeparator}empty')..createSync(recursive: true),
        <String, String>{declarationFile: 'classes:\n  "*": product\n'},
      );
      expect(auditOf(empty).findings(), <Matcher>[isA<NoGeneratorNamesAValuesFile>()]);
    });
  });
}

/// What [audit] read out of the one manifest at [manifest].
List<NamedValueFile> _entriesOf(ValueFilesAudit audit, String manifest) => audit
    .namedFiles()
    .where((NamedValueFile each) => each.manifest == manifest)
    .toList(growable: false);

/// A repository the counter-probe measures.
///
/// One catalog naming two apps of which only one carries the file the generator names for both; one
/// generator reading through a ref nothing declares and one entry relative to a source with no chart
/// path; and one list written as a flow sequence, which the reader does not follow and has to say so
/// rather than pass over.
SourceTree _plantedRepository(Directory parent) {
  final Directory root = Directory('${parent.path}${Platform.pathSeparator}tree')
    ..createSync(recursive: true);
  return SourceTree.planted(root, <String, String>{
    declarationFile: '''
classes:
  "apps/*/values-common.yaml": product
  "platform/values-common.yaml": product
  "cluster/profile.yaml": install
''',
    'platform/values-common.yaml': 'planted: {}\n',
    'cluster/profile.yaml': 'global: {}\n',
    'apps/present/values-common.yaml': 'planted: {}\n',
    'argocd/dev/apps/applicationset.yaml': r'''
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
spec:
  generators:
    - list:
        elements:
          - name: present
          - name: gone
  template:
    spec:
      sources:
        - repoURL: &repo "https://github.com/simetrixch/hostyour-cloud.git"
          targetRevision: &branch master
          ref: values
        - repoURL: *repo
          targetRevision: *branch
          path: "apps/{{ .name }}"
          helm:
            valueFiles:
              - $values/platform/values-common.yaml
              - values-common.yaml
              - $values/cluster/profile.yaml
            ignoreMissingValueFiles: true
''',
    'argocd/dev/apps/consumers-appset.yaml': r'''
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
spec:
  template:
    spec:
      sources:
        - repoURL: "https://github.com/simetrixch/hostyour-cloud.git"
          path: apps/present
          helm:
            valueFiles:
              - $absent/platform/values-common.yaml
        - repoURL: "https://github.com/simetrixch/hostyour-cloud.git"
          helm:
            valueFiles:
              - values-common.yaml
''',
    'argocd/dev/apps/slaves-appset.yaml': r'''
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
spec:
  template:
    spec:
      sources:
        - repoURL: "https://github.com/simetrixch/hostyour-cloud.git"
          path: apps/present
          helm:
            valueFiles: [values-common.yaml]
''',
  });
}
