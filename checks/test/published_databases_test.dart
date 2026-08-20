import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// published-databases — over the real tree, and over planted ones.
///
/// **Why every probe plants BOTH halves.** The subject of this check is a pair of objects that do
/// not reference each other: a route that says where a database is reached from, and a policy that
/// says whether the connection may arrive. A probe that planted only one of them would prove the
/// reader finds a file, not that the check holds the two together — so each defect below plants a
/// complete app and changes exactly one thing about it.
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

  group('the tree as it stands', () {
    test('every database published on an entry point is admitted through by its own policy', () {
      final Map<String, Object?> global = platformGlobal();
      final Object? ingressNamespace = global['ingressNamespace'];
      expect(
        ingressNamespace,
        isA<String>().having((String each) => each.isNotEmpty, 'is named', isTrue),
        reason: 'the namespace the two DB policies admit is what this check holds them to',
      );

      final List<PublishedApp> apps = <PublishedApp>[];
      for (final FileSystemEntity each in Directory('${repository.path}/apps').listSync()) {
        final Directory templates = Directory('${each.path}/templates');
        final File declared = File('${each.path}/values-common.yaml');
        if (!templates.existsSync() || !declared.existsSync()) {
          continue;
        }
        final Object? parsed = loadYaml(declared.readAsStringSync());
        final Map<String, Object?> values = <String, Object?>{
          if (parsed is Map) ...Map<String, Object?>.from(parsed),
          'global': global,
        };

        final String name = each.uri.pathSegments[each.uri.pathSegments.length - 2];
        final List<PublishedRoute> routes = <PublishedRoute>[];
        final List<PolicyDocument> policies = <PolicyDocument>[];
        int routeFiles = 0;
        for (final FileSystemEntity file in templates.listSync()) {
          if (file is! File || !file.path.endsWith('.yaml')) {
            continue;
          }
          final String template = file.readAsStringSync();
          if (file.path.endsWith('ingressroutetcp.yaml')) {
            routeFiles++;
          }
          if (routeIn(template: template, values: values) case final PublishedRoute route) {
            routes.add(route);
          }
          if (policyIn(template: template, values: values) case final PolicyDocument policy) {
            policies.add(policy);
          }
        }
        // A file the reader stopped recognising would take its route out of the audit and leave the
        // run green, which is the one way this check could quietly stop covering its subject.
        expect(
          routes,
          hasLength(routeFiles),
          reason:
              'apps/$name carries $routeFiles route files and the reader found ${routes.length}',
        );

        if (routes.isEmpty) {
          apps.add(PublishedApp(app: name, route: null, policies: policies));
          continue;
        }
        for (final PublishedRoute route in routes) {
          apps.add(PublishedApp(app: name, route: route, policies: policies));
        }
      }

      // WHAT THIS RUN COVERED, written out rather than counted. A check that only asserted "some
      // app publishes something" would go on passing after the last route left the tree, and a
      // green run would then mean nobody was looking. A database added here makes this line red
      // until somebody says so on purpose.
      expect(
        apps
            .where((PublishedApp each) => each.route != null)
            .map((PublishedApp each) => each.app)
            .toSet(),
        <String>{'mongodb', 'redis'},
        reason: 'these are the databases this repository publishes outside their own cluster',
      );
      expect(
        auditPublishedDatabases(
          apps: apps,
          ingressNamespace: ingressNamespace! as String,
        ).map((ExposureFinding each) => each.toString()),
        isEmpty,
      );
    });
  });

  group('what a route says', () {
    const String template = '''
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
spec:
  entryPoints:
    - {{ .Values.tailnetEntryPoint }}
  routes:
    - match: HostSNI(`*`)
      services:
        # A comment naming a port: 1 that is not one.
        - name: mongodb-{{ .Values.global.env }}
          port: {{ .Values.mongodb.containerPort }}
''';

    test('the entry point and the port are read out of the values that fill them', () {
      final PublishedRoute? route = routeIn(
        template: template,
        values: <String, Object?>{
          'tailnetEntryPoint': 'mongodb',
          'mongodb': <String, Object?>{'containerPort': 27017},
          'global': <String, Object?>{'env': 'dev'},
        },
      );

      expect(route?.entryPoint, 'mongodb');
      expect(route?.port, 27017);
      expect(route?.service, 'mongodb-{{ .Values.global.env }}');
    });

    test('a value the template names and the values do not resolves to nothing', () {
      // What a text match would miss: the template is unchanged and the value under it is gone.
      final PublishedRoute? route = routeIn(
        template: template,
        values: <String, Object?>{
          'mongodb': <String, Object?>{'containerPort': 27017},
          'global': <String, Object?>{'env': 'dev'},
        },
      );

      expect(route?.entryPoint, isNull);
      expect(route?.port, 27017);
    });

    test('THE INNOCENT NEIGHBOUR: a template that is not an IngressRouteTCP declares no route', () {
      expect(
        routeIn(
          template: 'kind: Service\nspec:\n  ports:\n    - port: 27017\n',
          values: <String, Object?>{},
        ),
        isNull,
      );
    });
  });

  group('what a policy admits', () {
    const String template = '''
kind: NetworkPolicy
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: mongodb
  policyTypes:
    - Ingress
  ingress:
    - from:
        {{- range .Values.global.dbConsumerNamespaces }}
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ . | quote }}
        {{- end }}
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: {{ .Values.global.ingressNamespace | quote }}
        - podSelector: {}
      ports:
        - protocol: TCP
          port: 27017
''';

    final Map<String, Object?> values = <String, Object?>{
      'global': <String, Object?>{
        'dbConsumerNamespaces': <String>['dbgate'],
        'ingressNamespace': 'ingress',
      },
    };

    test('the workload it selects, the namespaces it admits and the port it admits them on', () {
      final PolicyDocument? policy = policyIn(template: template, values: values);

      expect(policy?.selects, 'mongodb');
      expect(policy?.rules, hasLength(1));
      expect(policy?.rules.single.namespaces, <String>{'dbgate', 'ingress'});
      expect(policy?.rules.single.ports, <int>{27017});
      expect(policy?.rules.single.allPorts, isFalse);
      expect(policy?.covers('mongodb'), isTrue);
      expect(policy?.covers('redis'), isFalse);
    });

    test('a namespace admitted through a range is admitted, not passed over', () {
      // A reader that only understood a literal would call this policy empty and refuse a chart
      // that is correct — a false refusal costs the same trust as a false pass.
      final PolicyDocument? policy = policyIn(
        template: template,
        values: <String, Object?>{
          'global': <String, Object?>{
            'dbConsumerNamespaces': <String>['dbgate', 'ingress'],
            'ingressNamespace': 'somewhere-else',
          },
        },
      );

      expect(policy?.rules.single.admits('ingress', 27017), isTrue);
    });

    test('a rule that names no ports admits every port', () {
      final PolicyDocument? policy = policyIn(
        template:
            'kind: NetworkPolicy\nspec:\n'
            '  podSelector: {}\n'
            '  ingress:\n'
            '    - from:\n'
            '        - namespaceSelector:\n'
            '            matchLabels:\n'
            '              kubernetes.io/metadata.name: "ingress"\n',
        values: <String, Object?>{},
      );

      expect(policy?.selects, isNull);
      expect(policy?.covers('anything'), isTrue);
      expect(policy?.rules.single.allPorts, isTrue);
      expect(policy?.rules.single.admits('ingress', 6379), isTrue);
    });

    test('two rules are two rules, and each carries its own ports', () {
      final PolicyDocument? policy = policyIn(
        template:
            'kind: NetworkPolicy\nspec:\n'
            '  podSelector: {}\n'
            '  ingress:\n'
            '    - from:\n'
            '        - namespaceSelector:\n'
            '            matchLabels:\n'
            '              kubernetes.io/metadata.name: "observability"\n'
            '      ports:\n'
            '        - port: 9216\n'
            '    - from:\n'
            '        - namespaceSelector:\n'
            '            matchLabels:\n'
            '              kubernetes.io/metadata.name: "ingress"\n'
            '      ports:\n'
            '        - port: 27017\n',
        values: <String, Object?>{},
      );

      expect(policy?.rules, hasLength(2));
      expect(policy?.rules.first.admits('ingress', 27017), isFalse);
      expect(policy?.rules.last.admits('ingress', 27017), isTrue);
    });

    test('THE INNOCENT NEIGHBOUR: a template that is not a NetworkPolicy declares no policy', () {
      expect(
        policyIn(template: 'kind: Deployment\nspec: {}\n', values: <String, Object?>{}),
        isNull,
      );
    });
  });

  group('what it reports', () {
    PublishedApp planted({
      required String app,
      String? entryPoint = 'mongodb',
      int? port = 27017,
      List<PolicyDocument> policies = const <PolicyDocument>[],
    }) => PublishedApp(
      app: app,
      route: PublishedRoute(entryPoint: entryPoint, service: '$app-dev', port: port),
      policies: policies,
    );

    PolicyDocument admitting(String app, Set<String> namespaces, Set<int> ports) => PolicyDocument(
      selects: app,
      rules: <PolicyRule>[
        PolicyRule(namespaces: namespaces, ports: ports, allPorts: ports.isEmpty),
      ],
    );

    test('THE INNOCENT: a route whose policy admits the controller on the routed port', () {
      expect(
        auditPublishedDatabases(
          apps: <PublishedApp>[
            planted(
              app: 'mongodb',
              policies: <PolicyDocument>[
                admitting('mongodb', <String>{'dbgate', 'ingress'}, <int>{27017}),
              ],
            ),
          ],
          ingressNamespace: 'ingress',
        ),
        isEmpty,
      );
    });

    test('THE INNOCENT NEIGHBOUR: an app that publishes nothing is judged on nothing', () {
      // An app with no route has no second half to be missing, and reporting its missing policy
      // would demand a NetworkPolicy of every chart in the tree.
      expect(
        auditPublishedDatabases(
          apps: <PublishedApp>[
            const PublishedApp(app: 'coredns', route: null, policies: <PolicyDocument>[]),
          ],
          ingressNamespace: 'ingress',
        ),
        isEmpty,
      );
    });

    test('the planted defect: a published database with no policy covering its workload', () {
      final List<ExposureFinding> found = auditPublishedDatabases(
        apps: <PublishedApp>[
          planted(
            app: 'redis',
            entryPoint: 'redis',
            port: 6379,
            policies: <PolicyDocument>[
              admitting('mongodb', <String>{'ingress'}, <int>{27017}),
            ],
          ),
        ],
        ingressNamespace: 'ingress',
      );

      expect(found.single, isA<UnpolicedDatabase>());
      expect(found.single.toString(), contains('every pod of the cluster'));
    });

    test('the planted defect: a policy that admits everyone except the controller', () {
      final List<ExposureFinding> found = auditPublishedDatabases(
        apps: <PublishedApp>[
          planted(
            app: 'mongodb',
            policies: <PolicyDocument>[
              admitting('mongodb', <String>{'dbgate'}, <int>{27017}),
            ],
          ),
        ],
        ingressNamespace: 'ingress',
      );

      expect(found.single, isA<UnadmittedController>());
      expect(found.single.toString(), contains('dropped by Calico'));
    });

    test('the planted defect: the controller admitted, but on another port', () {
      // The two objects agree that the controller may come in and disagree about where to, which
      // reads as a working policy in a diff and as a closed port on the machine.
      final List<ExposureFinding> found = auditPublishedDatabases(
        apps: <PublishedApp>[
          planted(
            app: 'mongodb',
            policies: <PolicyDocument>[
              admitting('mongodb', <String>{'ingress'}, <int>{9216}),
            ],
          ),
        ],
        ingressNamespace: 'ingress',
      );

      expect(found.single, isA<UnadmittedController>());
      expect(found.single.toString(), contains('port 27017'));
    });

    test('the planted defect: a route whose entry point resolves to nothing', () {
      final List<ExposureFinding> found = auditPublishedDatabases(
        apps: <PublishedApp>[
          planted(
            app: 'mongodb',
            entryPoint: null,
            policies: <PolicyDocument>[
              admitting('mongodb', <String>{'ingress'}, <int>{27017}),
            ],
          ),
        ],
        ingressNamespace: 'ingress',
      );

      expect(found.single, isA<UnresolvedRoute>());
      expect(found.single.toString(), contains('entry point'));
    });

    test('the planted defect: two databases on one entry point', () {
      final List<ExposureFinding> found = auditPublishedDatabases(
        apps: <PublishedApp>[
          planted(
            app: 'mongodb',
            policies: <PolicyDocument>[
              admitting('mongodb', <String>{'ingress'}, <int>{27017}),
            ],
          ),
          planted(
            app: 'redis',
            policies: <PolicyDocument>[
              admitting('redis', <String>{'ingress'}, <int>{27017}),
            ],
          ),
        ],
        ingressNamespace: 'ingress',
      );

      expect(found.single, isA<SharedEntryPoint>());
      expect(found.single.toString(), contains('one port on the machine'));
    });

    test('the three failures are three findings, not one', () {
      // The whole reason this check exists: from the client's side an unpoliced database, an
      // unadmitted controller and a route that resolves to nothing are one symptom.
      final List<ExposureFinding> found = auditPublishedDatabases(
        apps: <PublishedApp>[
          planted(app: 'one', entryPoint: 'one'),
          planted(
            app: 'two',
            entryPoint: 'two',
            policies: <PolicyDocument>[
              admitting('two', <String>{'dbgate'}, <int>{27017}),
            ],
          ),
          planted(
            app: 'three',
            entryPoint: null,
            policies: <PolicyDocument>[
              admitting('three', <String>{'ingress'}, <int>{27017}),
            ],
          ),
        ],
        ingressNamespace: 'ingress',
      );

      expect(found.map((ExposureFinding each) => each.runtimeType.toString()), <String>[
        'UnpolicedDatabase',
        'UnadmittedController',
        'UnresolvedRoute',
      ]);
    });
  });
}
