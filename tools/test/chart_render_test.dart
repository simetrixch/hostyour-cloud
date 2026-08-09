import 'dart:io';

import 'package:hostyour_cloud_gate/hostyour_cloud_gate.dart';
import 'package:test/test.dart';

import 'support/repository_under_check.dart';

/// Every chart of this repository renders, the way ArgoCD renders it.
///
/// The audit is [ChartRenderAudit] and it decides everything; this file drives it twice. Once over
/// the repository, where its findings must be empty. Once over a tree planted for the purpose,
/// where each planted defect must come back — a check that cannot go red proves nothing about the
/// tree it passes on, and a render audit that rendered nothing looks exactly like one that found
/// nothing wrong.
void main() {
  final Directory scratch = Directory.systemTemp.createTempSync('hostyour-render-');
  final File installationValues = const InstallationValues().writeInto(scratch);
  final SourceTree tree = repositoryTree();

  final ChartRenderAudit audit = ChartRenderAudit(
    tree: tree,
    helm: const ProcessHelm(),
    installationValues: installationValues.path,
  );

  tearDownAll(() => scratch.deleteSync(recursive: true));

  group('the repository', () {
    test('carries neither of the two install-branch positions of the stack', () {
      expect(
        audit.installationStateOnTheTrunk(),
        isEmpty,
        reason:
            'the fixture stands in for exactly those two positions, and the substitution is only '
            'lossless while the trunk really is empty in them',
      );
    });

    test('names a chart directory for every entry of every stage catalog', () {
      expect(audit.catalogEntriesWithoutACharts(), isEmpty);
    });

    test('names an app the catalog carries in every cluster/apps toggle', () {
      expect(audit.togglesWithoutACatalogEntry(), isEmpty);
    });

    test('is deployed by an ArgoCD manifest in every one of its charts', () {
      expect(audit.chartsNothingDeploys(), isEmpty);
    });

    test('the stages it renders for are the stages this tree carries', () {
      // The denominator above is only worth something if the stage list cannot be collapsed by
      // editing one constant. This is what holds it: the tree says which stages exist by carrying a
      // values file for each, and the constant the renders are driven by has to agree.
      // Which stages, not in which order. The order is a decision — dev before test before prod is
      // how a release travels — and the tree states existence, not sequence.
      expect(
        audit.stagesDeclared,
        (List<String>.of(stages)..sort()),
        reason:
            'platform/values-<stage>.yaml is how a stage says it exists here; a constant that has '
            'more or fewer than the tree renders a coverage nobody can read off the tree',
      );
    });

    test('renders every chart, for every stage and size it carries', () {
      final List<RenderFinding> found = audit.renders();
      expect(found, isEmpty, reason: found.map((RenderFinding f) => f.describe()).join('\n'));
      expect(
        audit.rendersPerformed,
        audit.rendersExpected,
        reason:
            'every chart, for every stage it is rendered at, at every size it carries. Equality and '
            'not a floor: a floor of one render per chart is satisfied by exactly the state a stage '
            'collapse produces, and being walked over is indistinguishable from being sound',
      );
    });
  });

  group('the value stack is the one ArgoCD layers', () {
    // The order of the files is the whole of what makes a render faithful, and it cannot be seen in
    // the manifests: two stacks in the wrong order both render, and one of them renders something
    // nobody deploys. So it is asserted against what the generator writes, through a helm that
    // records instead of running.

    test('a catalog chart gets the files of applicationset.yaml, in that order', () {
      final FakeHelm helm = FakeHelm();
      final SourceTree planted = _plantedRepository(scratch, 'stack-catalog');
      ChartRenderAudit(
        tree: planted,
        helm: helm,
        installationValues: '/fixture/installation-values.yaml',
      ).renders();

      final ChartRender rendered = helm.renders.firstWhere(
        (ChartRender each) => each.releaseName == 'planted',
      );
      expect(rendered.valueFiles, <String>[
        '../../platform/values-common.yaml',
        '../../platform/values-dev.yaml',
        'values-common.yaml',
        'values-dev.yaml',
        '../../cluster/values/planted.yaml',
        '../../cluster/profile.yaml',
        '/fixture/installation-values.yaml',
      ]);
    });

    test('a unit chart gets its sizing preset where a stage file would stand', () {
      final FakeHelm helm = FakeHelm();
      final SourceTree planted = _plantedRepository(scratch, 'stack-unit');
      ChartRenderAudit(
        tree: planted,
        helm: helm,
        installationValues: '/fixture/installation-values.yaml',
      ).renders();

      final ChartRender rendered = helm.renders.firstWhere(
        (ChartRender each) => each.releaseName == 'sizedunit',
      );
      expect(rendered.valueFiles, contains('values-size-small.yaml'));
      expect(
        rendered.valueFiles,
        isNot(contains('values-dev.yaml')),
        reason:
            'a unit chart is a template and has no stage identity of its own; what makes such a '
            'render belong to a stage is the platform file above the preset, never a file the '
            'chart carries itself',
      );
    });

    test('the ceiling chart gets no values file and the six figures a registration carries', () {
      final FakeHelm helm = FakeHelm();
      final SourceTree planted = _plantedRepository(scratch, 'stack-quota');
      ChartRenderAudit(
        tree: planted,
        helm: helm,
        installationValues: '/fixture/installation-values.yaml',
      ).renders();

      final ChartRender rendered = helm.renders.firstWhere(
        (ChartRender each) => each.releaseName == 'unit-quota',
      );
      expect(rendered.valueFiles, isEmpty);
      expect(rendered.values.keys, hasLength(6));
      expect(rendered.values['quota.requestsCpu'], isNotEmpty);
    });
  });

  group('counter-probe', () {
    late Directory probeRoot;
    late SourceTree probe;

    setUp(() {
      probeRoot = Directory.systemTemp.createTempSync('hostyour-render-probe-');
      probe = _plantedRepository(probeRoot, 'tree');
    });
    tearDown(() => probeRoot.deleteSync(recursive: true));

    ChartRenderAudit auditOf(SourceTree tree, {Helm? helm}) => ChartRenderAudit(
      tree: tree,
      helm: helm ?? const ProcessHelm(),
      installationValues: installationValues.path,
    );

    test('a catalog entry with no chart directory is reported', () {
      expect(
        auditOf(probe).catalogEntriesWithoutACharts(),
        contains(
          isA<CatalogNamesNoChart>().having((CatalogNamesNoChart f) => f.app, 'app', 'absent'),
        ),
      );
    });

    test('a toggle naming an app no catalog carries is reported', () {
      expect(
        auditOf(probe).togglesWithoutACatalogEntry(),
        contains(
          isA<ToggleNamesNoCatalogEntry>().having(
            (ToggleNamesNoCatalogEntry f) => f.named,
            'named',
            'orphan',
          ),
        ),
      );
    });

    test('a toggle stating no name at all is reported', () {
      expect(
        auditOf(probe).togglesWithoutACatalogEntry(),
        contains(
          isA<ToggleNamesNoCatalogEntry>().having(
            (ToggleNamesNoCatalogEntry f) => f.named,
            'named',
            isNull,
          ),
        ),
      );
    });

    test('a chart no manifest names is reported', () {
      expect(
        auditOf(probe).chartsNothingDeploys(),
        contains(
          isA<ChartNothingDeploys>().having((ChartNothingDeploys f) => f.app, 'app', 'lonely'),
        ),
      );
    });

    test('installation state standing on the trunk is reported', () {
      expect(
        auditOf(probe).installationStateOnTheTrunk(),
        contains(
          isA<InstallationStateOnTheTrunk>().having(
            (InstallationStateOnTheTrunk f) => f.path,
            'path',
            'cluster/values/planted.yaml',
          ),
        ),
      );
    });

    test('a template reaching for a value nothing sets is reported', () {
      expect(
        auditOf(probe).renders(),
        contains(
          isA<ChartDidNotRender>()
              .having((ChartDidNotRender f) => f.app, 'app', 'planted')
              .having((ChartDidNotRender f) => f.reason, 'reason', contains('planted.absent')),
        ),
        reason: 'helm rendered a template whose required value nothing in the stack sets',
      );
    });

    test('a rendered document with no kind is reported', () {
      expect(
        auditOf(probe).renders(),
        contains(
          isA<RenderedDocumentRejected>()
              .having((RenderedDocumentRejected f) => f.app, 'app', 'kindless')
              .having((RenderedDocumentRejected f) => f.missing, 'missing', 'has no kind'),
        ),
      );
    });

    test('a helm that is not there is reported rather than passed over', () {
      final List<RenderFinding> found = auditOf(probe, helm: FakeHelm(available: false)).renders();
      expect(found, <Matcher>[isA<NothingCouldBeRendered>()]);
    });

    test('a complete resource and an empty document are not reported', () {
      const RenderedManifest manifest = RenderedManifest(
        '---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: fine\n---\n',
      );
      expect(
        manifest.rejections,
        isEmpty,
        reason:
            'a chart that renders an empty conditional block emits a null document, and reporting '
            'it would make every second chart red for a `{{- if }}` that was false',
      );
    });
  });
}

/// A repository the counter-probe measures: a catalog naming one chart that renders, one that emits
/// a document with no kind and one that does not exist; two toggles the generator cannot merge; a
/// chart no manifest names; one installation's own values standing on the trunk; and the two unit
/// families, whose stacks differ from the catalog's.
SourceTree _plantedRepository(Directory parent, String name) {
  final Directory root = Directory('${parent.path}${Platform.pathSeparator}$name')
    ..createSync(recursive: true);
  const String requiredValue = '{{ required "planted.absent is required" .Values.planted.absent }}';
  return SourceTree.planted(root, <String, String>{
    'platform/values-common.yaml': 'global:\n  timezone: Europe/Amsterdam\n',
    for (final String stage in stages) 'platform/values-$stage.yaml': 'global:\n  env: $stage\n',
    'cluster/profile.yaml': 'global: {}\n',
    'cluster/values/planted.yaml': 'global:\n  domain: m1.example.com\n',
    'cluster/apps/orphan.yaml': 'name: orphan\ndeploy: "false"\n',
    'cluster/apps/nameless.yaml': 'deploy: "false"\n',
    'argocd/dev/apps/applicationset.yaml': '''
spec:
  generators:
    - merge:
        generators:
          - list:
              elements:
                - name: planted
                - name: kindless
                - name: absent
''',
    'argocd/dev/apps/consumers-appset.yaml': '''
spec:
  template:
    spec:
      sources:
        - path: apps/sizedunit
        - path: apps/unit-quota
''',
    'apps/planted/Chart.yaml': 'apiVersion: v2\nname: planted\nversion: 1.0.0\n',
    'apps/planted/values-common.yaml': 'planted: {}\n',
    for (final String stage in stages) 'apps/planted/values-$stage.yaml': 'planted: {}\n',
    'apps/planted/templates/configmap.yaml':
        'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: planted\ndata:\n'
        '  absent: "$requiredValue"\n',
    'apps/kindless/Chart.yaml': 'apiVersion: v2\nname: kindless\nversion: 1.0.0\n',
    'apps/kindless/values-common.yaml': 'planted: {}\n',
    for (final String stage in stages) 'apps/kindless/values-$stage.yaml': 'planted: {}\n',
    'apps/kindless/templates/configmap.yaml': 'planted: a document with no kind\n',
    'apps/lonely/Chart.yaml': 'apiVersion: v2\nname: lonely\nversion: 1.0.0\n',
    'apps/sizedunit/Chart.yaml': 'apiVersion: v2\nname: sizedunit\nversion: 1.0.0\n',
    'apps/sizedunit/values.yaml': 'planted: {}\n',
    'apps/sizedunit/values-size-small.yaml': 'planted: {}\n',
    'apps/sizedunit/templates/configmap.yaml':
        'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: sizedunit\n',
    'apps/unit-quota/Chart.yaml': 'apiVersion: v2\nname: unit-quota\nversion: 1.0.0\n',
    'apps/unit-quota/values.yaml': 'quota: {}\n',
    'apps/unit-quota/templates/quota.yaml':
        'apiVersion: v1\nkind: ResourceQuota\nmetadata:\n  name: unit-quota\n',
  });
}
