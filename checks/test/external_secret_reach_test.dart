import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// external-secret-reach — over the real trees, and over planted ones.
///
/// **Why both sides are read and neither may be missing.** The four instances this check was built
/// after were each a valid ExternalSecret against a valid role, and what was wrong stood in the
/// other repository. So the suite refuses over an unfindable installation, over an empty admission
/// and over an empty reader set, rather than passing because it found nothing to compare.
///
/// **What is not proven here** is the shape a planted tree cannot carry: the refusal when there is
/// no installation at all, and the environment override that names one — the first is only reached
/// after the walk has passed every directory up to the root of the volume, and the second is read
/// from the process, which a test in the same process cannot set. `installation_tree.dart` carries
/// both, and `vault_selector_labels_test.dart` says the same about them.
void main() {
  final Directory repository = Directory.current.parent;

  group('the trees as they stand', () {
    late Admission admission;
    late Set<String> written;
    late List<SecretReader> readers;
    late List<RenderedStore> stores;
    late Map<String, ApplicationPlacement> placements;

    setUp(() {
      final _Installation programs = _programsOf(installationRoot());
      admission = programs.admission;
      written = programs.written;
      final _Applications applications = _applicationsOf(repository);
      readers = applications.readers;
      stores = applications.stores;
      placements = applications.placements;
    });

    test('a master and a slave each admit namespaces, and they are not the same list', () {
      expect(
        admission.onMaster,
        isNotEmpty,
        reason:
            'no row of any program admits a namespace for role "$listedRole" on a master — over '
            'an empty admission every reader of this tree would be reported, and a check that '
            'reports everything is read as a check that reports nothing',
      );
      expect(
        admission.onSlave,
        isNotEmpty,
        reason:
            'no row of any program admits a namespace for role "$listedRole" on a slave\'s own '
            'mount — held against the union of the two sides, a chart only a slave runs passes on '
            'a namespace only the master admits, which is the reading this check exists to refuse',
      );
      expect(
        admission.onSlave,
        isNot(equals(admission.onMaster)),
        reason:
            'the two sides having become one list is the shape that makes reading them apart '
            'pointless, and it would pass every slave-only chart on the master\'s wider list',
      );
    });

    test('the rows that decide nothing are the per-slave widening, and are named', () {
      expect(
        admission.passedOver,
        everyElement(contains(slavePlaceholder)),
        reason:
            'the only row this check may hold to nothing is the one admitting a namespace named '
            'after the slave a registration creates, which is not a name this repository writes',
      );
    });

    test('the programs write Vault entries, and the tree renders readers of them', () {
      expect(
        written,
        isNotEmpty,
        reason:
            'no vault_kv_entry row of any program writes an entry — every path of this tree would '
            'be reported, which says nothing about any of them',
      );
      expect(
        stores.where((RenderedStore each) => each.role == listedRole),
        isNotEmpty,
        reason:
            'no application renders a SecretStore of role "$listedRole" — nothing would be judged, '
            'and a green over an empty subject is the failure this check exists to refuse',
      );
      expect(readers, isNotEmpty, reason: 'a comparison against no readers reads like a pass');
    });

    test('every ExternalSecret of a listed-role store is admitted and reads a written entry', () {
      final ReachAudit audit = auditExternalSecretReach(
        readers: readers,
        stores: stores,
        placements: placements,
        admission: admission,
        written: written,
      );

      expect(
        audit.judged,
        isNotEmpty,
        reason:
            'every reader of this tree was passed over — the subject is empty, and the reasons in '
            'passedOver say why: ${audit.passedOver}',
      );
      expect(audit.findings.map((ReachFinding each) => each.toString()), isEmpty);
    });

    test('what was passed over is passed over for one of the two stated reasons', () {
      final ReachAudit audit = auditExternalSecretReach(
        readers: readers,
        stores: stores,
        placements: placements,
        admission: admission,
        written: written,
      );

      // The two shapes the library says it does not reach, and nothing else. A third reason
      // appearing here is a reader this check stopped judging without anybody deciding to.
      expect(
        audit.passedOver,
        everyElement(anyOf(contains('a template composes'), contains('logs in under role'))),
      );
    });
  });

  group('what a program admits', () {
    test('the list is read out of the body a program hands Vault, folded as written', () {
      // The shape the programs really write: a `>-` folded scalar whose lines join into one JSON
      // object. Read through the same YAML parse the suite uses, so the folding is proven.
      const String program = r'''
program:
  - step: vault_auth_role
    mount: <kubernetes-mount>
    role: external-secrets
    preserve_list: bound_service_account_namespaces
    body: >-
      {"bound_service_account_names":["external-secrets-sa"],
      "bound_service_account_namespaces":["argocd","redis"],
      "token_policies":["<cluster>-eso"],"ttl":"24h"}
''';
      final List<AdmittedNamespaces> found = admittedNamespacesIn(
        program: 'programs/one.yaml',
        document: loadYaml(program),
      );

      expect(found, hasLength(1));
      expect(found.single.role, listedRole);
      expect(found.single.namespaces, <String>['argocd', 'redis']);
      expect(found.single.onASlavesOwnMount, isFalse);
    });

    test('THE INNOCENT NEIGHBOUR: preserve_list NAMES the field and writes no list', () {
      // `preserve_list: bound_service_account_namespaces` is the argument that makes a role write a
      // widening rather than a replacement. Decoding it as a body would refuse over every program
      // carrying the very thing that keeps an earlier cluster's namespace alive.
      final List<AdmittedNamespaces> found = admittedNamespacesIn(
        program: 'programs/one.yaml',
        document: <String, Object?>{
          'step': 'vault_auth_role',
          'preserve_list': namespaceListField,
          'body': '{"bound_service_account_names":["external-secrets-sa"]}',
        },
      );

      expect(found, isEmpty);
    });

    test('a body binding by label selector rather than by list admits no namespace here', () {
      final List<AdmittedNamespaces> found = admittedNamespacesIn(
        program: 'programs/one.yaml',
        document: <String, Object?>{
          'role': 'consumer-eso',
          'body':
              r'{"bound_service_account_namespace_selector":'
              r'"{\"matchLabels\":{\"hostyour.cloud/consumer\":\"true\"}}"}',
        },
      );

      expect(found, isEmpty);
    });

    test('a list that cannot be read is an error naming the program, never a pass', () {
      expect(
        () => admittedNamespacesIn(
          program: 'programs/one.yaml',
          document: <String, Object?>{
            'role': listedRole,
            'body': '{"$namespaceListField":"argocd"}',
          },
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException each) => each.message,
            'message',
            allOf(contains('programs/one.yaml'), contains('rather than a list')),
          ),
        ),
      );
    });

    test('a mount named after a slave is a slave\'s own, and any other is a master\'s', () {
      List<AdmittedNamespaces> rowsOn(String mount, List<String> namespaces) =>
          admittedNamespacesIn(
            program: 'programs/one.yaml',
            document: <String, Object?>{
              'mount': mount,
              'role': listedRole,
              'body': '{"$namespaceListField":${namespaces.map((String e) => '"$e"').toList()}}',
            },
          );

      final Admission admission = admissionOf(<AdmittedNamespaces>[
        ...rowsOn('kubernetes-$slavePlaceholder', <String>['redis']),
        ...rowsOn('<kubernetes-mount>', <String>['redis', 'registry']),
      ]);

      expect(admission.onSlave, <String>{'redis'});
      expect(admission.onMaster, <String>{'redis', 'registry'});
    });

    test('a namespace only one row of a side admits is not admitted on that side', () {
      // The master's role is written by two rows guarded on mutually exclusive conditions, and
      // exactly one of them runs on a fresh installation. What is guaranteed is the intersection.
      List<AdmittedNamespaces> rowOf(List<String> namespaces) => admittedNamespacesIn(
        program: 'programs/one.yaml',
        document: <String, Object?>{
          'mount': '<kubernetes-mount>',
          'role': listedRole,
          'body': '{"$namespaceListField":${namespaces.map((String e) => '"$e"').toList()}}',
        },
      );

      final Admission admission = admissionOf(<AdmittedNamespaces>[
        ...rowOf(<String>['redis', 'registry']),
        ...rowOf(<String>['redis']),
      ]);

      expect(admission.onMaster, <String>{'redis'});
    });

    test('a row admitting only a placeholder decides nothing rather than emptying its side', () {
      final Admission admission = admissionOf(<AdmittedNamespaces>[
        ...admittedNamespacesIn(
          program: 'programs/register.yaml',
          document: <String, Object?>{
            'mount': '<kubernetes-mount>',
            'role': listedRole,
            'body': '{"$namespaceListField":["$slavePlaceholder"]}',
          },
        ),
        ...admittedNamespacesIn(
          program: 'programs/one.yaml',
          document: <String, Object?>{
            'mount': '<kubernetes-mount>',
            'role': listedRole,
            'body': '{"$namespaceListField":["redis"]}',
          },
        ),
      ]);

      expect(admission.onMaster, <String>{'redis'});
      expect(admission.passedOver, hasLength(1));
    });

    test('a row of another role is not this role\'s list', () {
      final Admission admission = admissionOf(
        admittedNamespacesIn(
          program: 'programs/one.yaml',
          document: <String, Object?>{
            'mount': '<kubernetes-mount>',
            'role': 'manager-host',
            'body': '{"$namespaceListField":["manager"]}',
          },
        ),
      );

      expect(admission.onMaster, isEmpty);
    });
  });

  group('what a program writes', () {
    test('the path of every vault_kv_entry row is an entry that exists afterwards', () {
      const String program = r'''
program:
  - step: vault_kv_entry
    mount: secret
    path: <stage>/app/redis
    fields: ['redis-password=REDIS_PASSWORD']
  - step: vault_kv_entry
    mount: secret
    path: <stage>/app/idp
    copy_from:
      path: <stage>/idp/bootstrap
''';
      expect(writtenVaultPathsIn(document: loadYaml(program)), <String>{
        '<stage>/app/redis',
        '<stage>/app/idp',
      });
    });

    test('THE INNOCENT NEIGHBOUR: a step that is not a vault_kv_entry writes no entry', () {
      // `path` is the field name of half the step vocabulary — a file written from a template
      // carries one too, and reading those as Vault entries would make every path look written.
      const String program = r'''
program:
  - step: write_file_from_template
    path: /srv/hostyour-cloud/cluster/profile.yaml
  - step: vault_mount
    path: secret
''';
      expect(writtenVaultPathsIn(document: loadYaml(program)), isEmpty);
    });
  });

  group('what a path names', () {
    test('a printf over the stage is the entry the programs write', () {
      expect(
        vaultPathOf(r'{{ printf "%s/app/registry" .Values.global.env }}', stage: null),
        '<stage>/app/registry',
      );
    });

    test('a per-stage values file writes the stage as a literal, and its own name says which', () {
      expect(vaultPathOf('dev/app/redis', stage: 'dev'), '<stage>/app/redis');
      expect(vaultPathOf('prod/app/redis', stage: 'prod'), '<stage>/app/redis');
    });

    test('THE INNOCENT NEIGHBOUR: a path with no stage in it passes through as written', () {
      expect(vaultPathOf('build/catalog/repo-pat', stage: 'dev'), 'build/catalog/repo-pat');
    });

    test('a printf over anything but the stage names no entry a program writes', () {
      // `build/<unit>/repo-pat` is written when that unit is onboarded, not by a row of a program,
      // so holding it to the written set would report a real credential as an unwritten one.
      expect(vaultPathOf(r'{{ printf "build/%s/repo-pat" $unit }}', stage: null), isNull);
      expect(vaultPathOf(r'{{ printf "%s/app/registry" $env }}', stage: null), isNull);
    });

    test('a path a template composes any other way names nothing readable', () {
      expect(vaultPathOf(r'{{ $vaultKey }}', stage: null), isNull);
      expect(vaultPathOf('', stage: null), isNull);
    });
  });

  group('what an application renders', () {
    test('a values block layered across per-stage files is ONE reader', () {
      final ApplicationReading reading = readApplication(
        application: 'apps/redis',
        placement: const ApplicationPlacement(
          application: 'apps/redis',
          namespace: 'redis',
          runsOn: 'slave',
        ),
        files: <String, String>{
          'apps/redis/Chart.yaml': _chart,
          'apps/redis/values-common.yaml': '''
secret-store: {}

externalsecret-redis:
  externalSecret:
    enabled: true
    name: redis-credentials
    data:
      - secretKey: redis-password
        property: redis-password
''',
          'apps/redis/values-dev.yaml': '''
externalsecret-redis:
  externalSecret:
    vaultPath: dev/app/redis
''',
          'apps/redis/values-prod.yaml': '''
externalsecret-redis:
  externalSecret:
    vaultPath: prod/app/redis
''',
        },
      );

      expect(reading.readers, hasLength(1));
      expect(reading.readers.single.namespace, 'redis');
      expect(reading.readers.single.storeName, defaultStoreName);
      expect(reading.readers.single.vaultPaths, <String>{'<stage>/app/redis'});
      expect(
        reading.readers.single.where,
        'apps/redis/values-dev.yaml, apps/redis/values-prod.yaml',
        reason: 'both files carry the path, and both are what somebody has to open',
      );
      expect(reading.stores, hasLength(1));
      expect(reading.stores.single.role, listedRole);
      expect(reading.stores.single.namespace, 'redis');
    });

    test(
      'THE INNOCENT NEIGHBOUR: an externalSecret block of no embedded chart is not a reader',
      () {
        // The values key is the dependency's alias, and a block hanging under anything else is a
        // value of some other chart that happens to spell the same word.
        final ApplicationReading reading = readApplication(
          application: 'apps/one',
          placement: const ApplicationPlacement(
            application: 'apps/one',
            namespace: 'one',
            runsOn: 'master',
          ),
          files: <String, String>{
            'apps/one/Chart.yaml': _chart,
            'apps/one/values-dev.yaml': '''
something-else:
  externalSecret:
    vaultPath: dev/app/nowhere
''',
          },
        );

        expect(reading.readers, isEmpty);
      },
    );

    test('a template document is read for its namespace, its store and its keys', () {
      final ApplicationReading reading = readApplication(
        application: 'apps/manager',
        placement: const ApplicationPlacement(
          application: 'apps/manager',
          namespace: 'manager',
          runsOn: 'master',
        ),
        files: <String, String>{
          'apps/manager/Chart.yaml': _chart,
          'apps/manager/templates/externalsecret-app.yaml': r'''
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: manager-app
  namespace: {{ .Release.Namespace }}
spec:
  secretStoreRef:
    name: {{ .Values.global.secretStoreName }}
    kind: SecretStore
  data:
    - secretKey: oidc-client-secret
      remoteRef:
        key: {{ printf "%s/app/manager" .Values.global.env }}
        property: oidc-client-secret
''',
        },
      );

      expect(reading.readers, hasLength(1));
      expect(reading.readers.single.namespace, 'manager');
      expect(reading.readers.single.storeName, defaultStoreName);
      expect(reading.readers.single.vaultPaths, <String>{'<stage>/app/manager'});
    });

    test('THE INNOCENT NEIGHBOUR: a CRD declaring the kind is not an object of it', () {
      // The vendored ExternalSecret CRD names `ExternalSecret` under spec.names.kind. Read as a
      // reader it would be an ExternalSecret in every application's namespace with no path at all.
      final ApplicationReading reading = readApplication(
        application: 'apps/external-secrets',
        placement: const ApplicationPlacement(
          application: 'apps/external-secrets',
          namespace: 'external-secrets',
          runsOn: 'every-cluster',
        ),
        files: <String, String>{
          'apps/external-secrets/Chart.yaml': _chart,
          'apps/external-secrets/templates/crd.yaml': '''
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: externalsecrets.external-secrets.io
spec:
  names:
    kind: ExternalSecret
''',
        },
      );

      expect(reading.readers, isEmpty);
    });

    test('a values block overriding the store role takes its readers out of the subject', () {
      final ApplicationReading reading = readApplication(
        application: 'apps/one',
        placement: const ApplicationPlacement(
          application: 'apps/one',
          namespace: 'one',
          runsOn: 'master',
        ),
        files: <String, String>{
          'apps/one/Chart.yaml': _chart,
          'apps/one/values-common.yaml': '''
secret-store:
  role: consumer-eso
''',
        },
      );

      expect(reading.stores.single.role, 'consumer-eso');
    });
  });

  group('what it reports', () {
    const ApplicationPlacement onASlave = ApplicationPlacement(
      application: 'apps/redis',
      namespace: 'redis',
      runsOn: 'slave',
    );
    const RenderedStore store = RenderedStore(
      where: 'apps/redis/Chart.yaml',
      namespace: 'redis',
      name: defaultStoreName,
      role: listedRole,
    );
    SecretReader readerOf(String path) => SecretReader(
      where: 'apps/redis/values-dev.yaml',
      application: 'apps/redis',
      namespace: 'redis',
      storeName: defaultStoreName,
      vaultPaths: <String>{path},
      unreadablePaths: const <String>{},
    );

    test('the planted defect: a namespace the side that runs it does not admit', () {
      final ReachAudit audit = auditExternalSecretReach(
        readers: <SecretReader>[readerOf('<stage>/app/redis')],
        stores: <RenderedStore>[store],
        placements: <String, ApplicationPlacement>{'apps/redis': onASlave},
        // The master admits `redis` and the slave does not, which is exactly what holding a chart
        // against the union rather than against its own side would pass.
        admission: const Admission(
          onMaster: <String>{'redis'},
          onSlave: <String>{'mongodb'},
          passedOver: <String>[],
        ),
        written: <String>{'<stage>/app/redis'},
      );

      expect(audit.findings, hasLength(1));
      expect(
        audit.findings.single.toString(),
        allOf(
          contains('apps/redis/values-dev.yaml'),
          contains('namespace "redis"'),
          contains('a slave'),
          contains('refused before any policy is consulted'),
        ),
      );
    });

    test('the planted defect: a path no vault_kv_entry row writes', () {
      final ReachAudit audit = auditExternalSecretReach(
        readers: <SecretReader>[readerOf('<stage>/app/observability-agent')],
        stores: <RenderedStore>[store],
        placements: <String, ApplicationPlacement>{'apps/redis': onASlave},
        admission: const Admission(
          onMaster: <String>{'redis'},
          onSlave: <String>{'redis'},
          passedOver: <String>[],
        ),
        written: <String>{'<stage>/app/redis'},
      );

      expect(audit.findings, hasLength(1));
      expect(
        audit.findings.single,
        isA<UnwrittenVaultPath>().having(
          (UnwrittenVaultPath each) => each.path,
          'path',
          '<stage>/app/observability-agent',
        ),
      );
    });

    test('the planted innocent: a reader admitted on its own side, reading a written entry', () {
      final ReachAudit audit = auditExternalSecretReach(
        readers: <SecretReader>[readerOf('<stage>/app/redis')],
        stores: <RenderedStore>[store],
        placements: <String, ApplicationPlacement>{'apps/redis': onASlave},
        admission: const Admission(
          onMaster: <String>{},
          onSlave: <String>{'redis'},
          passedOver: <String>[],
        ),
        written: <String>{'<stage>/app/redis'},
      );

      expect(audit.findings, isEmpty);
      expect(audit.judged, hasLength(1));
    });

    test('an every-cluster application is held to BOTH sides', () {
      final ReachAudit audit = auditExternalSecretReach(
        readers: <SecretReader>[readerOf('<stage>/app/redis')],
        stores: <RenderedStore>[store],
        placements: <String, ApplicationPlacement>{
          'apps/redis': const ApplicationPlacement(
            application: 'apps/redis',
            namespace: 'redis',
            runsOn: 'every-cluster',
          ),
        },
        admission: const Admission(
          onMaster: <String>{'redis'},
          onSlave: <String>{},
          passedOver: <String>[],
        ),
        written: <String>{'<stage>/app/redis'},
      );

      expect(audit.findings, hasLength(1));
      expect(audit.findings.single.toString(), contains('a slave'));
    });

    test('a reader whose store nothing renders into its namespace is reported, not passed over', () {
      // The hole this closes: a namespace no application sets a store up in is exactly a namespace
      // nothing admits, and passing it over would let the defect this check exists for through
      // whenever the ExternalSecret carries its own `namespace:`.
      final ReachAudit audit = auditExternalSecretReach(
        readers: <SecretReader>[
          const SecretReader(
            where: 'apps/redis/values-dev.yaml',
            application: 'apps/redis',
            namespace: 'redis-cache',
            storeName: defaultStoreName,
            vaultPaths: <String>{'<stage>/app/redis'},
            unreadablePaths: <String>{},
          ),
        ],
        stores: <RenderedStore>[store],
        placements: <String, ApplicationPlacement>{'apps/redis': onASlave},
        admission: const Admission(
          onMaster: <String>{'redis'},
          onSlave: <String>{'redis'},
          passedOver: <String>[],
        ),
        written: <String>{'<stage>/app/redis'},
      );

      expect(audit.passedOver, isEmpty);
      expect(audit.findings.single, isA<UnresolvableStore>());
      expect(audit.findings.single.toString(), contains('"redis-cache"'));
    });

    test('a reader through a store of another role is passed over by name, never judged', () {
      final ReachAudit audit = auditExternalSecretReach(
        readers: <SecretReader>[
          const SecretReader(
            where: 'apps/manager/templates/manager-host-secret.yaml',
            application: 'apps/manager',
            namespace: 'manager',
            storeName: 'vault-backend-manager',
            vaultPaths: <String>{'<stage>/manager-host/ssh'},
            unreadablePaths: <String>{},
          ),
        ],
        stores: <RenderedStore>[
          const RenderedStore(
            where: 'apps/manager/templates/manager-host-secret.yaml',
            namespace: 'manager',
            name: 'vault-backend-manager',
            role: 'manager-host',
          ),
        ],
        placements: <String, ApplicationPlacement>{
          'apps/manager': const ApplicationPlacement(
            application: 'apps/manager',
            namespace: 'manager',
            runsOn: 'master',
          ),
        },
        admission: const Admission(
          onMaster: <String>{},
          onSlave: <String>{},
          passedOver: <String>[],
        ),
        written: <String>{},
      );

      expect(audit.findings, isEmpty);
      expect(audit.judged, isEmpty);
      expect(audit.passedOver.single, contains('role "manager-host"'));
    });
  });

  group('what an app.yaml places', () {
    test('a namespace and a runsOn are read, and which sides they mean', () {
      final ApplicationPlacement? placement = placementIn(
        application: 'apps/redis',
        source: 'name: redis\nnamespace: redis\nrunsOn: slave\n',
      );

      expect(placement?.namespace, 'redis');
      expect(placement?.onASlave, isTrue);
      expect(placement?.onAMaster, isFalse);
    });

    test('a manifest naming no runsOn places nothing rather than guessing a side', () {
      expect(placementIn(application: 'apps/one', source: 'namespace: one\n'), isNull);
    });
  });
}

/// A `Chart.yaml` embedding both shared charts under the names the applications address them by.
const String _chart = '''
apiVersion: v2
name: one
dependencies:
  - name: secret-store
    version: 1.0.0
    repository: file://../../charts/secret-store
  - name: external-secret
    version: 1.0.0
    repository: file://../../charts/external-secret
    alias: externalsecret-redis
''';

/// What the deploy programs of one installation admit and write.
final class _Installation {
  const _Installation({required this.admission, required this.written});

  final Admission admission;
  final Set<String> written;
}

_Installation _programsOf(Directory installation) {
  final List<AdmittedNamespaces> rows = <AdmittedNamespaces>[];
  final Set<String> written = <String>{};
  for (final FileSystemEntity each in Directory(
    '${installation.path}/$installationPrograms',
  ).listSync(recursive: true, followLinks: false)) {
    if (each is! File || !_isYaml(each.path)) {
      continue;
    }
    final Object? document = loadYaml(each.readAsStringSync());
    rows.addAll(
      admittedNamespacesIn(program: _relative(each.path, installation), document: document),
    );
    written.addAll(writtenVaultPathsIn(document: document));
  }
  return _Installation(admission: admissionOf(rows), written: written);
}

/// What the platform applications of one repository render.
final class _Applications {
  const _Applications({required this.readers, required this.stores, required this.placements});

  final List<SecretReader> readers;
  final List<RenderedStore> stores;
  final Map<String, ApplicationPlacement> placements;
}

_Applications _applicationsOf(Directory repository) {
  final List<SecretReader> readers = <SecretReader>[];
  final List<RenderedStore> stores = <RenderedStore>[];
  final Map<String, ApplicationPlacement> placements = <String, ApplicationPlacement>{};

  for (final Directory each in Directory(
    '${repository.path}/apps',
  ).listSync().whereType<Directory>()) {
    final File manifest = File('${each.path}/app.yaml');
    if (!manifest.existsSync()) {
      continue;
    }
    final String application = _relative(each.path, repository);
    final ApplicationPlacement? placement = placementIn(
      application: application,
      source: manifest.readAsStringSync(),
    );
    expect(
      placement,
      isNotNull,
      reason:
          '$application/app.yaml names no namespace or no runsOn — which list admits its '
          'ExternalSecrets is then not decidable, and passing over it would be exactly the silence '
          'this check exists to break',
    );
    placements[application] = placement!;

    final Map<String, String> files = <String, String>{
      for (final FileSystemEntity file in each.listSync(recursive: true, followLinks: false))
        if (file is File && _isYaml(file.path))
          _relative(file.path, repository): file.readAsStringSync(),
    };
    final ApplicationReading reading = readApplication(
      application: application,
      placement: placement,
      files: files,
    );
    stores.addAll(reading.stores);
    readers.addAll(reading.readers);
  }

  return _Applications(readers: readers, stores: stores, placements: placements);
}

String _relative(String path, Directory from) =>
    p.relative(path, from: from.path).replaceAll(r'\', '/');

bool _isYaml(String path) => path.endsWith('.yaml') || path.endsWith('.yml');
