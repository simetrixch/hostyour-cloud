import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// published-databases — over the real tree, and over planted ones.
///
/// **Why the real-tree test states the databases by name.** The subject is derived from
/// `apps/<name>/app.yaml`, so a database moved out of the `data` project leaves the audit silently
/// and the run stays green with nothing looking. Naming them is what makes that move red.
///
/// **Why each planted defect changes exactly one thing.** Four different faults put a database
/// outside its cluster and none of them fails a render, so each probe below starts from the same
/// innocent app and alters one of the four — otherwise a green run would only prove that a defective
/// app is defective in some way, not that this check reports the fault it names.
void main() {
  final Directory repository = Directory.current.parent;

  /// The `global:` block every chart reads through `.Values.global`.
  Map<String, Object?> platformGlobal() {
    final Object? parsed = loadYaml(
      File('${repository.path}/platform/values-common.yaml').readAsStringSync(),
    );
    final Object? global = parsed is Map ? parsed['global'] : null;
    return global is Map ? Map<String, Object?>.from(global) : <String, Object?>{};
  }

  /// Every application under `apps/` whose manifest names the database project, read off disk.
  List<DatabaseApp> treeDatabases(Map<String, Object?> global) {
    final List<DatabaseApp> apps = <DatabaseApp>[];
    for (final FileSystemEntity each in Directory('${repository.path}/apps').listSync()) {
      final File manifest = File('${each.path}/app.yaml');
      if (!manifest.existsSync()) {
        continue;
      }
      final Object? declared = loadYaml(manifest.readAsStringSync());
      if (declared is! Map || declared['project'] != databaseProject) {
        continue;
      }
      final String name = each.uri.pathSegments[each.uri.pathSegments.length - 2];

      final Object? parsed = loadYaml(File('${each.path}/values-common.yaml').readAsStringSync());
      final Map<String, Object?> values = <String, Object?>{
        if (parsed is Map) ...Map<String, Object?>.from(parsed),
        'global': global,
      };

      final List<RouteDocument> routes = <RouteDocument>[];
      final List<PolicyDocument> policies = <PolicyDocument>[];
      for (final FileSystemEntity file in Directory('${each.path}/templates').listSync()) {
        if (file is! File || !file.path.endsWith('.yaml')) {
          continue;
        }
        final String template = file.readAsStringSync();
        final String where = 'apps/$name/templates/${file.uri.pathSegments.last}';
        routes.addAll(routeDocumentsIn(where: where, template: template));
        if (policyIn(template: template, values: values) case final PolicyDocument policy) {
          policies.add(policy);
        }
      }

      apps.add(
        DatabaseApp(
          app: name,
          routes: routes,
          dependencies: fileDependenciesIn(
            base: 'apps/$name',
            chart: File('${each.path}/Chart.yaml').readAsStringSync(),
          ),
          policies: policies,
        ),
      );
    }
    return apps;
  }

  group('the tree as it stands', () {
    test('no database of this repository is reachable from outside the cluster it runs in', () {
      final Map<String, Object?> global = platformGlobal();
      final Object? ingressNamespace = global['ingressNamespace'];
      expect(
        ingressNamespace,
        isA<String>().having((String each) => each.isNotEmpty, 'is named', isTrue),
        reason: 'the namespace this check refuses a database policy to admit has to be named',
      );

      final List<DatabaseApp> apps = treeDatabases(global);

      // WHAT THIS RUN COVERED, written out rather than counted. A database moved out of the `data`
      // project leaves this audit with nothing saying so, and a green run would then mean nobody was
      // looking. A database added here makes this line red until somebody says so on purpose.
      expect(apps.map((DatabaseApp each) => each.app).toSet(), <String>{
        'mongodb',
        'redis',
      }, reason: 'these are the applications this repository runs a database in');

      expect(
        auditPublishedDatabases(
          apps: apps,
          ingressNamespace: ingressNamespace! as String,
        ).map((ExposureFinding each) => each.toString()),
        isEmpty,
      );
    });

    test('THE COUNTER-PROBE: a route added to the real material turns this check red', () {
      // Not a planted app but the tree's own, with one object added — so what is proven is that the
      // reader that walked these very files would have reported it.
      final Map<String, Object?> global = platformGlobal();
      final List<DatabaseApp> apps = treeDatabases(global);
      final DatabaseApp subject = apps.firstWhere((DatabaseApp each) => each.app == 'mongodb');

      final List<ExposureFinding> found = auditPublishedDatabases(
        apps: <DatabaseApp>[
          DatabaseApp(
            app: subject.app,
            routes: <RouteDocument>[
              ...subject.routes,
              ...routeDocumentsIn(
                where: 'apps/mongodb/templates/ingressroutetcp.yaml',
                template: _plantedRoute,
              ),
            ],
            dependencies: subject.dependencies,
            policies: subject.policies,
          ),
        ],
        ingressNamespace: global['ingressNamespace']! as String,
      );

      expect(found.single, isA<PublishedDatabase>());
      expect(found.single.toString(), contains('apps/mongodb/templates/ingressroutetcp.yaml'));
      expect(found.single.toString(), contains('IngressRouteTCP'));
    });
  });

  group('what the audit reports', () {
    DatabaseApp planted({
      List<RouteDocument> routes = const <RouteDocument>[],
      Set<String> dependencies = const <String>{'charts/common'},
      List<PolicyDocument>? policies,
    }) => DatabaseApp(
      app: 'one',
      routes: routes,
      dependencies: dependencies,
      policies:
          policies ??
          <PolicyDocument>[
            const PolicyDocument(
              selects: 'one',
              rules: <PolicyRule>[
                PolicyRule(namespaces: <String>{'dbgate'}, ports: <int>{27017}, allPorts: false),
              ],
            ),
          ],
    );

    test('THE PLANTED INNOCENT: a database admitting its own cluster and publishing nothing', () {
      expect(
        auditPublishedDatabases(apps: <DatabaseApp>[planted()], ingressNamespace: 'ingress'),
        isEmpty,
      );
    });

    test('THE PLANTED DEFECT: a route out of the cluster', () {
      final List<ExposureFinding> found = auditPublishedDatabases(
        apps: <DatabaseApp>[
          planted(
            routes: const <RouteDocument>[
              RouteDocument(
                kind: 'IngressRouteTCP',
                where: 'apps/one/templates/ingressroutetcp.yaml',
                sendsTo: 'one-dev',
              ),
            ],
          ),
        ],
        ingressNamespace: 'ingress',
      );

      expect(found.single, isA<PublishedDatabase>());
      expect(found.single.toString(), contains('publishes apps/one outside the cluster'));
    });

    test('THE PLANTED DEFECT: the ingress chart embedded as a dependency', () {
      final List<ExposureFinding> found = auditPublishedDatabases(
        apps: <DatabaseApp>[
          planted(dependencies: const <String>{'charts/common', 'charts/ingress'}),
        ],
        ingressNamespace: 'ingress',
      );

      expect(found.single, isA<EmbeddedIngressChart>());
      expect(found.single.toString(), contains('ingress.enabled: true'));
    });

    test('THE PLANTED DEFECT: a policy rule admitting the ingress controller', () {
      final List<ExposureFinding> found = auditPublishedDatabases(
        apps: <DatabaseApp>[
          planted(
            policies: const <PolicyDocument>[
              PolicyDocument(
                selects: 'one',
                rules: <PolicyRule>[
                  PolicyRule(namespaces: <String>{'dbgate'}, ports: <int>{27017}, allPorts: false),
                  PolicyRule(namespaces: <String>{'ingress'}, ports: <int>{27017}, allPorts: false),
                ],
              ),
            ],
          ),
        ],
        ingressNamespace: 'ingress',
      );

      expect(found.single, isA<AdmittedController>());
      expect(found.single.toString(), contains('on 27017'));
      expect(found.single.toString(), contains('half of a publication'));
    });

    test('THE PLANTED DEFECT: no policy covers the workload at all', () {
      final List<ExposureFinding> found = auditPublishedDatabases(
        apps: <DatabaseApp>[
          planted(
            policies: const <PolicyDocument>[
              PolicyDocument(selects: 'another', rules: <PolicyRule>[]),
            ],
          ),
        ],
        ingressNamespace: 'ingress',
      );

      expect(found.single, isA<UnpolicedDatabase>());
      expect(found.single.toString(), contains('presents as a database that works'));
    });

    test('a rule naming no port at all is reported as reaching every one of them', () {
      final List<ExposureFinding> found = auditPublishedDatabases(
        apps: <DatabaseApp>[
          planted(
            policies: const <PolicyDocument>[
              PolicyDocument(
                selects: null,
                rules: <PolicyRule>[
                  PolicyRule(namespaces: <String>{'ingress'}, ports: <int>{}, allPorts: true),
                ],
              ),
            ],
          ),
        ],
        ingressNamespace: 'ingress',
      );

      expect(found.single.toString(), contains('every port'));
    });
  });

  group('what a template renders', () {
    test('an IngressRouteTCP is read as a route, and the object it names is printed', () {
      final List<RouteDocument> found = routeDocumentsIn(
        where: 'apps/one/templates/route.yaml',
        template: _plantedRoute,
      );

      expect(found, hasLength(1));
      expect(found.single.kind, 'IngressRouteTCP');
      expect(found.single.sendsTo, 'mongodb-{{ .Values.global.env }}');
    });

    test('an Ingress is a route too — a database is published by a host as well as by a port', () {
      final List<RouteDocument> found = routeDocumentsIn(
        where: 'apps/one/templates/ingress.yaml',
        template:
            'apiVersion: networking.k8s.io/v1\n'
            'kind: Ingress\n'
            'spec:\n'
            '  rules:\n'
            '    - host: db.example.invalid\n',
      );

      expect(found.single.kind, 'Ingress');
      expect(found.single.sendsTo, 'db.example.invalid');
    });

    test('THE INNOCENT NEIGHBOUR: a Service naming a port is not a route', () {
      expect(
        routeDocumentsIn(
          where: 'apps/one/templates/service.yaml',
          template:
              'apiVersion: v1\n'
              'kind: Service\n'
              'metadata:\n'
              '  name: one-dev\n'
              'spec:\n'
              '  ports:\n'
              '    - port: 27017\n',
        ),
        isEmpty,
      );
    });

    test('a file rendering two documents is read as two', () {
      final List<RouteDocument> found = routeDocumentsIn(
        where: 'apps/one/templates/both.yaml',
        template:
            'kind: Service\n'
            'metadata:\n'
            '  name: one-dev\n'
            '---\n'
            'kind: IngressRouteTCP\n'
            'spec:\n'
            '  routes:\n'
            '    - services:\n'
            '        - name: one-dev\n',
      );

      expect(found.single.kind, 'IngressRouteTCP');
    });
  });

  group('what a chart depends on', () {
    test('a file:// dependency is resolved against the chart it stands in', () {
      expect(
        fileDependenciesIn(
          base: 'apps/mongodb',
          chart:
              'dependencies:\n'
              '  - name: ingress\n'
              '    repository: file://../../charts/ingress\n',
        ),
        <String>{ingressChart},
      );
    });

    test('THE INNOCENT NEIGHBOUR: the library charts a database legitimately embeds', () {
      expect(
        fileDependenciesIn(
          base: 'apps/redis',
          chart:
              'dependencies:\n'
              '  - name: common\n'
              '    repository: file://../../charts/common\n'
              '  - name: deployment\n'
              '    repository: file://../../charts/deployment\n',
        ),
        <String>{'charts/common', 'charts/deployment'},
      );
    });

    test('a dependency pulled from a chart repository names no directory of this tree', () {
      expect(
        fileDependenciesIn(
          base: 'apps/redis',
          chart:
              'dependencies:\n'
              '  - name: prometheus-redis-exporter\n'
              '    repository: https://prometheus-community.github.io/helm-charts\n',
        ),
        isEmpty,
      );
    });
  });

  group('what a policy admits', () {
    const String template = '''
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: mongodb
  ingress:
    - from:
        {{- range .Values.global.dbConsumerNamespaces }}
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ . | quote }}
        {{- end }}
        - podSelector: {}
      ports:
        - protocol: TCP
          port: 27017
''';

    Map<String, Object?> values(List<String> named) => <String, Object?>{
      'global': <String, Object?>{'dbConsumerNamespaces': named},
    };

    test('a namespace admitted through a range is resolved through the range', () {
      final PolicyDocument? policy = policyIn(
        template: template,
        values: values(<String>['dbgate']),
      );

      expect(policy?.selects, 'mongodb');
      expect(policy?.rules.single.namespaces, <String>{'dbgate'});
      expect(policy?.rules.single.ports, <int>{27017});
      expect(policy?.rules.single.allPorts, isFalse);
    });

    test('THE COUNTER-PROBE: the same range holding the controller is read as admitting it', () {
      // What proves the range reader is not merely returning an empty set: put the controller's
      // own namespace in the list the template iterates, and the rule has to admit it.
      final PolicyDocument? policy = policyIn(
        template: template,
        values: values(<String>['dbgate', 'ingress']),
      );

      expect(policy?.rules.single.admits('ingress'), isTrue);
    });

    test('THE INNOCENT NEIGHBOUR: a document of another kind declares no policy', () {
      expect(
        policyIn(template: 'apiVersion: v1\nkind: Service\n', values: <String, Object?>{}),
        isNull,
      );
    });

    test('a podSelector matching every pod covers whatever app is asked about', () {
      final PolicyDocument? policy = policyIn(
        template:
            'kind: NetworkPolicy\n'
            'spec:\n'
            '  podSelector: {}\n'
            '  ingress:\n'
            '    - from:\n'
            '        - podSelector: {}\n',
        values: <String, Object?>{},
      );

      expect(policy?.selects, isNull);
      expect(policy?.covers('anything'), isTrue);
    });
  });

  group('what a value stands for', () {
    test('a reference is looked up in the values that fill it', () {
      expect(
        resolveValue('{{ .Values.global.ingressNamespace | quote }}', <String, Object?>{
          'global': <String, Object?>{'ingressNamespace': 'ingress'},
        }),
        'ingress',
      );
    });

    test('a reference the values do not answer resolves to nothing rather than to itself', () {
      expect(resolveValue('{{ .Values.missing }}', <String, Object?>{}), isNull);
    });

    test('a composed string is not guessed at', () {
      expect(resolveValue('gate-{{ .Values.name }}.example.invalid', <String, Object?>{}), isNull);
    });

    test('THE INNOCENT NEIGHBOUR: a literal passes through as written', () {
      expect(resolveValue('"ingress"', <String, Object?>{}), 'ingress');
    });
  });
}

/// One IngressRouteTCP, as apps/mongodb carried it until hostyour-cloud#66 removed it.
const String _plantedRoute = '''
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: mongodb-{{ .Values.global.env }}
spec:
  entryPoints:
    - {{ .Values.tailnetEntryPoint }}
  routes:
    - match: HostSNI(`*`)
      services:
        # A comment naming a name: that is not one.
        - name: mongodb-{{ .Values.global.env }}
          port: {{ .Values.mongodb.containerPort }}
''';
