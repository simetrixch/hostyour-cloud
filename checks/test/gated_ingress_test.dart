import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// gated-ingress — over the real trees, and over the real material altered one thing at a time.
///
/// **Why the counter-probes start from `apps/dbgate` rather than from a planted app.** The defect
/// this check exists for is one line: `enabled: false` becoming `enabled: true` in a file whose
/// annotation names a middleware that stands in another cluster. So the probes take that very file,
/// change that one switch, and run the reader that walked it — what is proven is that the reader
/// would have reported the change somebody makes, not that a fixture of the right shape is
/// reportable.
///
/// **Why the innocent neighbour renders a middleware of its own.** A check that refused every
/// Ingress on this application would be a ban, and the ticket asks for the opposite: the day there
/// IS a gate in the slave's own cluster, the switch has to go on without this suite standing in the
/// way. `charts/middleware` is the mechanism that makes that possible — `apps/observability` already
/// uses it — so the neighbour embeds it exactly as observability does.
///
/// **What is not proven here** is what `installation_tree.dart` carries: the refusal when no
/// installation tree is findable, and the environment override that names one.
void main() {
  final Directory repository = Directory.current.parent;

  String relative(String path) => p.relative(path, from: repository.path).replaceAll(r'\', '/');

  /// The `Chart.yaml` and every values file of the application at [application], by path.
  Map<String, String> filesOf(String application) {
    final Map<String, String> files = <String, String>{};
    for (final FileSystemEntity each in Directory('${repository.path}/$application').listSync()) {
      if (each is! File || !each.path.endsWith('.yaml')) {
        continue;
      }
      final String name = p.basename(each.path);
      if (name == 'Chart.yaml' || name.startsWith('values')) {
        files['$application/$name'] = each.readAsStringSync();
      }
    }
    return files;
  }

  /// Every application under `apps/` that states a namespace and a `runsOn`.
  Map<String, ApplicationPlacement> treePlacements() {
    final Map<String, ApplicationPlacement> placements = <String, ApplicationPlacement>{};
    for (final FileSystemEntity each in Directory('${repository.path}/apps').listSync()) {
      final File manifest = File('${each.path}/app.yaml');
      if (!manifest.existsSync()) {
        continue;
      }
      final String application = relative(each.path);
      final ApplicationPlacement? placement = placementIn(
        application: application,
        source: manifest.readAsStringSync(),
      );
      if (placement != null) {
        placements[application] = placement;
      }
    }
    return placements;
  }

  /// Which cluster roles each manifest of this repository is applied for, out of the installation's
  /// own programs.
  Map<String, Set<String>> treeManifestRoles() {
    final List<ProgramManifests> programs = <ProgramManifests>[];
    final Directory directory = Directory('${installationRoot().path}/$installationPrograms');
    for (final FileSystemEntity each in directory.listSync()) {
      if (each is! File || !each.path.endsWith('.yaml')) {
        continue;
      }
      programs.add(
        programManifestsIn(
          program: '$installationPrograms/${p.basename(each.path)}',
          document: loadYaml(each.readAsStringSync()),
        ),
      );
    }
    return manifestRolesOf(programs);
  }

  /// Every Middleware the manifests under `bootstrap/` declare, placed by the programs applying
  /// them.
  List<RenderedMiddleware> bootstrapMiddlewares(Map<String, Set<String>> roles) {
    final List<RenderedMiddleware> found = <RenderedMiddleware>[];
    for (final FileSystemEntity each in Directory(
      '${repository.path}/bootstrap',
    ).listSync(recursive: true)) {
      if (each is! File || !each.path.endsWith('.yaml')) {
        continue;
      }
      final String where = relative(each.path);
      for (final MiddlewareObject object in middlewareObjectsIn(
        where: where,
        source: each.readAsStringSync(),
      )) {
        found.add(placedMiddleware(object: object, roles: roles[where] ?? const <String>{}));
      }
    }
    return found;
  }

  group('the trees as they stand', () {
    late Map<String, ApplicationPlacement> placements;
    late Map<String, Set<String>> manifestRoles;
    late List<RenderedIngress> ingresses;
    late List<RenderedMiddleware> middlewares;

    setUp(() {
      placements = treePlacements();
      manifestRoles = treeManifestRoles();
      ingresses = <RenderedIngress>[];
      middlewares = bootstrapMiddlewares(manifestRoles);
      for (final MapEntry<String, ApplicationPlacement> each in placements.entries) {
        final GateReading reading = readApplicationGates(
          application: each.key,
          placement: each.value,
          files: filesOf(each.key),
        );
        ingresses.addAll(reading.ingresses);
        middlewares.addAll(reading.middlewares);
      }
    });

    test('the programs place the manifests of this repository, and the forwardAuth one is one', () {
      expect(
        manifestRoles['bootstrap/idp/middleware-forwardauth.yaml'],
        <String>{masterRole},
        reason:
            'the middleware apps/dbgate and apps/tekton name is applied by a program declaring '
            'roles: [$masterRole] — read as applied nowhere, every Ingress naming it would be '
            'reported, and read as applied everywhere the defect this check exists for passes',
      );
    });

    test('this repository renders these Ingresses, and these gates in front of them', () {
      // WHAT THIS RUN COVERED, written out rather than counted. An Ingress switched on is a
      // published workload, and one that appears here without anybody saying so is what this line
      // makes red. apps/dbgate is deliberately absent: its switch is off.
      expect(
        ingresses.map((RenderedIngress each) => '${each.application} ${each.key}').toSet(),
        <String>{
          'apps/manager ingress',
          'apps/observability ingress-loki-push',
          'apps/observability ingress-prom-push',
          'apps/registry ingress',
          'apps/tailnet-coordinator ingress',
          'apps/tekton ingress',
        },
        reason: 'these are the Ingresses this repository renders out of $ingressChart',
      );
      expect(
        middlewares.map((RenderedMiddleware each) => each.reference).toSet(),
        <String?>{
          'idp-forwardauth$crdProvider',
          'vault-vault-oidc-redirect$crdProvider',
          'observability-obs-push-auth$crdProvider',
        },
        reason:
            'both mechanisms are read — the manifests of bootstrap/ and the $middlewareChart '
            'renders of apps/ — and a check that saw only one of them would refuse a correct '
            'configuration',
      );
    });

    test('every Ingress this repository renders is answered in the cluster it stands in', () {
      final GateAudit audit = auditGatedIngress(
        ingresses: ingresses,
        placements: placements,
        middlewares: middlewares,
      );

      expect(
        audit.judged,
        isNotEmpty,
        reason:
            'no Ingress of this tree was judged — a green over an empty subject is the failure '
            'this check exists to refuse',
      );
      expect(audit.passedOver, isEmpty, reason: 'every reference of this tree names $crdProvider');
      expect(audit.findings.map((GateFinding each) => each.toString()), isEmpty);
    });
  });

  group('the real material with one thing changed', () {
    late Map<String, ApplicationPlacement> placements;
    late List<RenderedMiddleware> platform;

    setUp(() {
      placements = treePlacements();
      platform = bootstrapMiddlewares(treeManifestRoles());
    });

    /// The files of `apps/dbgate` with its Ingress switched on, and nothing else changed.
    Map<String, String> dbgateSwitchedOn() {
      const String off = '    enabled: false\n';
      final Map<String, String> files = filesOf('apps/dbgate');
      final String source = files['apps/dbgate/values-common.yaml']!;
      expect(
        source,
        contains(off),
        reason:
            'apps/dbgate/values-common.yaml no longer renders its Ingress off in the words this '
            'probe flips — the probe is measuring nothing and has to be re-aimed',
      );
      files['apps/dbgate/values-common.yaml'] = source.replaceFirst(off, '    enabled: true\n');
      return files;
    }

    GateAudit auditOf(
      Map<String, String> files, {
      List<RenderedMiddleware> also = const <RenderedMiddleware>[],
    }) {
      final GateReading reading = readApplicationGates(
        application: 'apps/dbgate',
        placement: placements['apps/dbgate']!,
        files: files,
      );
      return auditGatedIngress(
        ingresses: reading.ingresses,
        placements: placements,
        middlewares: <RenderedMiddleware>[...platform, ...reading.middlewares, ...also],
      );
    }

    test('THE COUNTER-PROBE: the switch on, and the middleware it names is in another cluster', () {
      final GateAudit audit = auditOf(dbgateSwitchedOn());

      expect(audit.judged, hasLength(1));
      expect(audit.findings.single, isA<GateInAnotherCluster>());
      expect(audit.findings.single.application, 'apps/dbgate');
      expect(audit.findings.single.toString(), contains('idp-forwardauth$crdProvider'));
      expect(
        audit.findings.single.toString(),
        contains('THE CLUSTER is what the two halves do not share'),
        reason: 'the refusal has to say WHICH of the two halves is missing',
      );
      expect(
        audit.findings.single.toString(),
        contains('bootstrap/idp/middleware-forwardauth.yaml'),
        reason: 'and where the half that exists stands, so the reader knows what to move',
      );
      expect(audit.findings.single.toString(), contains('runs on a slave'));
    });

    test('THE COUNTER-PROBE: the switch on, naming a middleware nothing renders anywhere', () {
      final Map<String, String> files = dbgateSwitchedOn();
      files['apps/dbgate/values-common.yaml'] = files['apps/dbgate/values-common.yaml']!
          .replaceFirst('idp-forwardauth$crdProvider', 'dbgate-nothing-renders-this$crdProvider');

      final GateAudit audit = auditOf(files);

      expect(audit.findings.single, isA<UnrenderedGate>());
      expect(
        audit.findings.single.toString(),
        contains('THE MIDDLEWARE is the half that is missing'),
      );
      expect(
        audit.findings.single.toString(),
        contains('idp-forwardauth$crdProvider'),
        reason: 'what IS rendered is named, so a near miss reads as one',
      );
    });

    test('THE COUNTER-PROBE: the switch on, with the annotation gone entirely', () {
      // The hole an annotation-only check would leave. dbgate carries $skipAllAuthVariable, so an
      // Ingress with no gate named at all publishes every database of its cluster as root.
      final Map<String, String> files = dbgateSwitchedOn();
      files['apps/dbgate/values-common.yaml'] = files['apps/dbgate/values-common.yaml']!
          .replaceFirst(
            '    annotations:\n'
                '      $middlewareAnnotation: idp-forwardauth$crdProvider\n',
            '',
          );

      final GateAudit audit = auditOf(files);

      expect(audit.findings.single, isA<UngatedIngress>());
      expect(audit.findings.single.toString(), contains(skipAllAuthVariable));
      expect(audit.findings.single.toString(), contains('no annotation even asks for one'));
    });

    test('THE INNOCENT NEIGHBOUR: the same switch on, over a gate in its own cluster', () {
      // What the ticket asks for in so many words: this is not a request to forbid the Ingress. The
      // application embeds charts/middleware exactly as apps/observability does, names the object it
      // renders, and the audit has nothing to say.
      final Map<String, String> files = dbgateSwitchedOn();
      files['apps/dbgate/Chart.yaml'] =
          '${files['apps/dbgate/Chart.yaml']!}\n'
          '  - name: middleware\n'
          '    version: 1.0.0\n'
          '    repository: file://../../$middlewareChart\n'
          '    alias: gate-auth\n';
      files['apps/dbgate/values-common.yaml'] =
          '${files['apps/dbgate/values-common.yaml']!.replaceFirst('idp-forwardauth$crdProvider', 'dbgate-dbgate-gate-auth$crdProvider')}\n'
          'gate-auth:\n'
          '  fullnameOverride: dbgate-gate-auth\n'
          '  middleware:\n'
          '    enabled: true\n'
          '    type: basicAuth\n'
          '    basicAuth:\n'
          '      secretName: dbgate-gate-htpasswd\n';

      final GateAudit audit = auditOf(files);

      expect(
        audit.judged,
        hasLength(1),
        reason: 'the Ingress is on and judged — a pass because nothing was read is not a pass',
      );
      expect(audit.findings.map((GateFinding each) => each.toString()), isEmpty);
    });

    test(
      'THE INNOCENT NEIGHBOUR: the same switch on, gated by the forwardAuth of its own cluster',
      () {
        // The second half of the same statement: the mechanism is not what decides, the CLUSTER is.
        // A forwardAuth middleware applied on a slave as well answers this very annotation.
        final GateAudit audit = auditOf(
          dbgateSwitchedOn(),
          also: <RenderedMiddleware>[
            const RenderedMiddleware(
              where: 'bootstrap/idp/middleware-forwardauth.yaml',
              namespace: 'idp',
              name: 'forwardauth',
              onAMaster: true,
              onASlave: true,
            ),
          ],
        );

        expect(audit.findings.map((GateFinding each) => each.toString()), isEmpty);
      },
    );
  });

  group('what an application renders', () {
    const ApplicationPlacement onASlave = ApplicationPlacement(
      application: 'apps/one',
      namespace: 'one',
      runsOn: 'slave',
    );

    const String chart = '''
apiVersion: v2
name: one
dependencies:
  - name: ingress
    version: 1.0.0
    repository: file://../../charts/ingress
  - name: middleware
    version: 1.0.0
    repository: file://../../charts/middleware
    alias: one-auth
''';

    test('an Ingress switched off renders nothing to hold', () {
      final GateReading reading = readApplicationGates(
        application: 'apps/one',
        placement: onASlave,
        files: <String, String>{
          'apps/one/Chart.yaml': chart,
          'apps/one/values-common.yaml':
              '''
ingress:
  ingress:
    enabled: false
    annotations:
      $middlewareAnnotation: idp-forwardauth$crdProvider
    tls:
      enabled: true
''',
        },
      );

      expect(reading.ingresses, isEmpty);
    });

    test('THE INNOCENT NEIGHBOUR: tls.enabled is not the switch that renders the object', () {
      // Both are written `enabled:` and apps/dbgate has the first false and the second true, so a
      // reader taking any `enabled: true` of the block would report an Ingress that does not exist.
      final GateReading reading = readApplicationGates(
        application: 'apps/one',
        placement: onASlave,
        files: <String, String>{
          'apps/one/Chart.yaml': chart,
          'apps/one/values-common.yaml': '''
ingress:
  ingress:
    enabled: false
    tls:
      enabled: true
''',
        },
      );

      expect(reading.ingresses, isEmpty);
    });

    test('a block layered across per-stage files is ONE Ingress', () {
      final GateReading reading = readApplicationGates(
        application: 'apps/one',
        placement: onASlave,
        files: <String, String>{
          'apps/one/Chart.yaml': chart,
          'apps/one/values-common.yaml':
              '''
ingress:
  ingress:
    enabled: false
    annotations:
      $middlewareAnnotation: one-one-auth$crdProvider
''',
          'apps/one/values-dev.yaml': '''
ingress:
  ingress:
    enabled: true
''',
        },
      );

      expect(reading.ingresses, hasLength(1));
      expect(reading.ingresses.single.middlewares, <String>['one-one-auth$crdProvider']);
      expect(
        reading.ingresses.single.where,
        'apps/one/values-common.yaml, apps/one/values-dev.yaml',
        reason: 'both files carry the block, and both are what somebody has to open',
      );
    });

    test('a middleware block of the embedded chart stands in the namespace of its release', () {
      final GateReading reading = readApplicationGates(
        application: 'apps/one',
        placement: onASlave,
        files: <String, String>{
          'apps/one/Chart.yaml': chart,
          'apps/one/values-common.yaml': '''
one-auth:
  fullnameOverride: one-gate
  middleware:
    enabled: true
    type: basicAuth
''',
        },
      );

      expect(reading.middlewares.single.reference, 'one-one-gate$crdProvider');
      expect(reading.middlewares.single.onASlave, isTrue);
      expect(reading.middlewares.single.onAMaster, isFalse);
    });

    test('a middleware the values switch off renders no object', () {
      final GateReading reading = readApplicationGates(
        application: 'apps/one',
        placement: onASlave,
        files: <String, String>{
          'apps/one/Chart.yaml': chart,
          'apps/one/values-common.yaml': '''
one-auth:
  fullnameOverride: one-gate
  middleware:
    enabled: false
''',
        },
      );

      expect(reading.middlewares, isEmpty);
    });

    test('a middleware with no fullnameOverride answers no reference, and is still recorded', () {
      // charts/middleware names its object through common.fullname, which is the release name —
      // `<app>-<stage>` here — so the name differs per stage and no literal annotation can name it.
      final GateReading reading = readApplicationGates(
        application: 'apps/one',
        placement: onASlave,
        files: <String, String>{
          'apps/one/Chart.yaml': chart,
          'apps/one/values-common.yaml': '''
one-auth:
  middleware:
    enabled: true
''',
        },
      );

      expect(reading.middlewares.single.name, isNull);
      expect(reading.middlewares.single.reference, isNull);
      expect(reading.middlewares.single.toString(), contains('whose name the release composes'));
    });

    test('an embedded middleware the values say nothing about renders, as its chart defaults', () {
      final GateReading reading = readApplicationGates(
        application: 'apps/one',
        placement: onASlave,
        files: <String, String>{'apps/one/Chart.yaml': chart},
      );

      expect(
        reading.middlewares,
        hasLength(1),
        reason:
            '$middlewareChart/values.yaml opens with middleware.enabled: true, so a chart that '
            'embeds it and writes no block still renders the object',
      );
    });
  });

  group('what a manifest declares', () {
    test('a Middleware document is read for its namespace and its name', () {
      final List<MiddlewareObject> found = middlewareObjectsIn(
        where: 'bootstrap/idp/middleware-forwardauth.yaml',
        source: '''
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: forwardauth
  namespace: idp
spec:
  forwardAuth:
    address: http://idp-authentik-server.idp.svc.cluster.local:80/auth
''',
      );

      expect(found.single.namespace, 'idp');
      expect(found.single.name, 'forwardauth');
    });

    test('THE INNOCENT NEIGHBOUR: an IngressRoute REFERENCING one declares no second object', () {
      // bootstrap/vault/ingressroute.yaml is exactly this shape — one Middleware and one route that
      // names it under spec.routes[].middlewares. Reading the reference as an object would place a
      // middleware in a namespace nothing renders one into.
      final List<MiddlewareObject> found = middlewareObjectsIn(
        where: 'bootstrap/vault/ingressroute.yaml',
        source: '''
kind: Middleware
metadata:
  name: vault-oidc-redirect
  namespace: vault
---
kind: IngressRoute
metadata:
  name: vault
  namespace: vault
spec:
  routes:
    - middlewares:
        - name: vault-oidc-redirect
          namespace: vault
''',
      );

      expect(found, hasLength(1));
      expect(found.single.name, 'vault-oidc-redirect');
    });
  });

  group('what a program applies', () {
    test('the manifests of a program are placed by the roles that program declares', () {
      const String program = '''
name: deploy-gitops
roles: [master]
program:
  - step: kubernetes_object
    manifest: bootstrap/idp/middleware-forwardauth.yaml
  - step: kubernetes_object_irreversible
    manifest: argocd/root-app.yaml
''';
      final ProgramManifests found = programManifestsIn(
        program: 'programs/deploy-gitops.yaml',
        document: loadYaml(program),
      );

      expect(found.roles, <String>{masterRole});
      expect(found.manifests, <String>{
        'bootstrap/idp/middleware-forwardauth.yaml',
        'argocd/root-app.yaml',
      });
    });

    test('a manifest two programs apply stands in the roles of both', () {
      final Map<String, Set<String>> roles = manifestRolesOf(<ProgramManifests>[
        const ProgramManifests(
          program: 'programs/a.yaml',
          roles: <String>{masterRole},
          manifests: <String>{'bootstrap/one.yaml'},
        ),
        const ProgramManifests(
          program: 'programs/b.yaml',
          roles: <String>{slaveRole},
          manifests: <String>{'bootstrap/one.yaml'},
        ),
      ]);

      expect(roles['bootstrap/one.yaml'], <String>{masterRole, slaveRole});
    });

    test('a manifest no program applies stands in no cluster', () {
      final Map<String, Set<String>> roles = manifestRolesOf(<ProgramManifests>[
        const ProgramManifests(
          program: 'programs/a.yaml',
          roles: <String>{masterRole},
          manifests: <String>{'bootstrap/one.yaml'},
        ),
      ]);
      final RenderedMiddleware placed = placedMiddleware(
        object: const MiddlewareObject(where: 'bootstrap/two.yaml', namespace: 'two', name: 'gate'),
        roles: roles['bootstrap/two.yaml'] ?? const <String>{},
      );

      expect(placed.onAMaster, isFalse);
      expect(placed.onASlave, isFalse);
      expect(placed.sides, 'no cluster at all');
    });
  });

  group('what the audit reports', () {
    const Map<String, ApplicationPlacement> placements = <String, ApplicationPlacement>{
      'apps/one': ApplicationPlacement(
        application: 'apps/one',
        namespace: 'one',
        runsOn: 'every-cluster',
      ),
    };

    RenderedIngress ingress({List<String> middlewares = const <String>[]}) => RenderedIngress(
      where: 'apps/one/values-common.yaml',
      application: 'apps/one',
      key: 'ingress',
      middlewares: middlewares,
      skipsAllAuth: false,
    );

    test('an every-cluster application is held to BOTH sides', () {
      final GateAudit audit = auditGatedIngress(
        ingresses: <RenderedIngress>[
          ingress(middlewares: <String>['one-gate$crdProvider']),
        ],
        placements: placements,
        middlewares: <RenderedMiddleware>[
          const RenderedMiddleware(
            where: 'apps/one/values-common.yaml',
            namespace: 'one',
            name: 'gate',
            onAMaster: true,
            onASlave: false,
          ),
        ],
      );

      expect(audit.findings.single, isA<GateInAnotherCluster>());
      expect(audit.findings.single.toString(), contains('runs on a slave'));
    });

    test('an annotation naming two middlewares is held to both of them', () {
      final GateAudit audit = auditGatedIngress(
        ingresses: <RenderedIngress>[
          ingress(middlewares: <String>['one-gate$crdProvider', 'one-second$crdProvider']),
        ],
        placements: placements,
        middlewares: <RenderedMiddleware>[
          const RenderedMiddleware(
            where: 'apps/one/values-common.yaml',
            namespace: 'one',
            name: 'gate',
            onAMaster: true,
            onASlave: true,
          ),
        ],
      );

      expect(audit.findings.single, isA<UnrenderedGate>());
      expect(audit.findings.single.toString(), contains('one-second$crdProvider'));
    });

    test('a reference of another provider is passed over by name, never reported', () {
      final GateAudit audit = auditGatedIngress(
        ingresses: <RenderedIngress>[
          ingress(middlewares: <String>['redirect@file']),
        ],
        placements: placements,
        middlewares: const <RenderedMiddleware>[],
      );

      expect(audit.findings, isEmpty);
      expect(audit.passedOver.single, contains('redirect@file'));
    });

    test('THE INNOCENT NEIGHBOUR: an Ingress naming none, on a pod that has its own login', () {
      final GateAudit audit = auditGatedIngress(
        ingresses: <RenderedIngress>[ingress()],
        placements: placements,
        middlewares: const <RenderedMiddleware>[],
      );

      expect(audit.judged, hasLength(1));
      expect(audit.findings, isEmpty);
    });

    test('an annotation value is split on the comma Traefik splits it on', () {
      expect(referencesIn('one-a$crdProvider, one-b$crdProvider'), <String>[
        'one-a$crdProvider',
        'one-b$crdProvider',
      ]);
    });
  });

  group('what a pod says about its own authentication', () {
    test('the switch is the value beside the name, not the name alone', () {
      expect(
        skipsAllAuthIn(<String>['    - name: $skipAllAuthVariable', '      value: "true"']),
        isTrue,
      );
      expect(
        skipsAllAuthIn(<String>['    - name: $skipAllAuthVariable', '      value: "false"']),
        isFalse,
      );
    });

    test('THE INNOCENT NEIGHBOUR: a pod that names it nowhere asks who is calling', () {
      expect(
        skipsAllAuthIn(<String>['    - name: CONNECTIONS', '      value: "mongo,redis"']),
        isFalse,
      );
    });
  });
}
