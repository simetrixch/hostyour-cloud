import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// registration-selectors — over the real trees, and over planted ones.
///
/// **Why both sides are read and neither may be missing.** The selector the build fan-out matches
/// registrations by and the type those registrations carry the field in were written in two
/// repositories and never held against each other. So the suite refuses over an unfindable
/// Controller and refuses over an empty side, instead of passing because it found nothing to
/// compare.
///
/// **What is not proven here.** The registrations themselves: they stand on the install branch each
/// generator names as its `revision:`, not on this one, so what a written file holds is measured by
/// the Controller's own suite (`server/domains/onboarding/registry.test.ts:174-186`) and not here.
void main() {
  final Directory repository = Directory.current.parent;

  group('the trees as they stand', () {
    test('every selector over registrations/ matches a value the Controller can write', () {
      final List<RegistrationSelector> selectors = <RegistrationSelector>[];
      for (final File each in _applicationSetsOf(repository)) {
        selectors.addAll(
          registrationSelectorsIn(
            appset: p.relative(each.path, from: repository.path).replaceAll(r'\', '/'),
            document: loadYaml(each.readAsStringSync()),
          ),
        );
      }
      expect(
        selectors,
        isNotEmpty,
        reason:
            'no ApplicationSet of this tree selects the files it reads out of registrations/ — over '
            'nothing to hold to the fields the Controller declares, a green here would say nothing, '
            'and saying nothing green is the failure this check exists to refuse',
      );

      final Directory controller = controllerRoot();
      final List<DeclaredField> fields = <DeclaredField>[];
      for (final FileSystemEntity each in Directory(
        '${controller.path}/$controllerShared',
      ).listSync(recursive: true, followLinks: false)) {
        if (each is File && each.path.endsWith('.ts')) {
          fields.addAll(registrationFieldsIn(each.readAsStringSync()));
        }
      }
      expect(
        fields,
        isNotEmpty,
        reason:
            'no registration schema was read out of ${controller.path}/$controllerShared — every '
            'selector would then be reported as selecting a field nobody declares, which says '
            'nothing about the selectors and everything about the reading',
      );

      expect(
        auditRegistrationSelectors(
          selectors: selectors,
          fields: fields,
        ).map((SelectorFinding each) => each.toString()),
        isEmpty,
      );
    });

    test('the build fan-out selects suspended, and the Controller declares it a boolean', () {
      // The pair this check was built after, named on both sides so a move of either is reported
      // here rather than discovered by a fan-out that renders nothing.
      final List<RegistrationSelector> selectors = registrationSelectorsIn(
        appset: 'apps/consumer-build/files/applicationset.yaml',
        document: loadYaml(
          File(
            '${repository.path}/apps/consumer-build/files/applicationset.yaml',
          ).readAsStringSync(),
        ),
      );

      expect(selectors, hasLength(1));
      expect(selectors.single.key, 'suspended');
      expect(selectors.single.value, 'false');
      expect(selectors.single.valueIsString, isTrue);
      expect(selectors.single.glob, 'registrations/*/build.yaml');

      final List<DeclaredField> fields = registrationFieldsIn(
        File('${controllerRoot().path}/$controllerShared/consumer.ts').readAsStringSync(),
      );

      expect(
        fields
            .where((DeclaredField each) => each.name == 'suspended')
            .map((DeclaredField each) => '${each.schema}.${each.name}: z.${each.type}'),
        <String>['ConsumerRegistrationSchema.suspended: z.boolean'],
      );
    });
  });

  group('which generators are the subject', () {
    test('a git generator over registrations/ carries its selector', () {
      const String appset = '''
spec:
  generators:
    - git:
        files:
          - path: "registrations/*/build.yaml"
      selector:
        matchLabels:
          suspended: "false"
''';

      final List<RegistrationSelector> found = registrationSelectorsIn(
        appset: 'one.yaml',
        document: loadYaml(appset),
      );

      expect(found, hasLength(1));
      expect(found.single.glob, 'registrations/*/build.yaml');
      expect(found.single.key, 'suspended');
    });

    test('a git generator inside a matrix carries the OUTER entry selector', () {
      // The tenants shape: the files sit two levels down and the selector ArgoCD applies is the one
      // beside the matrix (generator_spec_processor.go:89 reads requestedGenerator.Selector).
      const String appset = '''
spec:
  generators:
    - matrix:
        generators:
          - git:
              files:
                - path: "registrations/*/prod.yaml"
          - git:
              repoURL: https://example.invalid/charts.git
      selector:
        matchLabels:
          cluster: m1
''';

      final List<RegistrationSelector> found = registrationSelectorsIn(
        appset: 'one.yaml',
        document: loadYaml(appset),
      );

      expect(found, hasLength(1));
      expect(found.single.glob, 'registrations/*/prod.yaml');
      expect(found.single.key, 'cluster');
    });

    test('THE INNOCENT NEIGHBOUR: a generator over cluster maps is not this check\'s subject', () {
      // argocd/apps/slaves-appset.yaml selects clusters/active/*.yaml by role, stage and
      // books-cluster — keys of a cluster map, held by appset-cluster-map-keys and not by anything
      // the Controller declares in a registration schema.
      const String appset = '''
spec:
  generators:
    - git:
        files:
          - path: "clusters/active/*.yaml"
      selector:
        matchLabels:
          role: slave
''';

      expect(registrationSelectorsIn(appset: 'one.yaml', document: loadYaml(appset)), isEmpty);
    });

    test('a generator with no selector matches every registration and is reported as nothing', () {
      const String appset = '''
spec:
  generators:
    - git:
        files:
          - path: "registrations/*/build.yaml"
''';

      expect(registrationSelectorsIn(appset: 'one.yaml', document: loadYaml(appset)), isEmpty);
    });

    test('a selector that cannot be read is an error naming the appset, never a pass', () {
      const String appset = '''
spec:
  generators:
    - git:
        files:
          - path: "registrations/*/build.yaml"
      selector:
        matchExpressions:
          - key: suspended
            operator: NotIn
            values: ["true"]
''';

      expect(
        () => registrationSelectorsIn(appset: 'one.yaml', document: loadYaml(appset)),
        throwsA(
          isA<FormatException>()
              .having((FormatException refused) => refused.message, 'message', contains('one.yaml'))
              .having(
                (FormatException refused) => refused.message,
                'message',
                contains('matchExpressions'),
              ),
        ),
      );
    });
  });

  group('what the Controller declares', () {
    const String schema = '''
export const ConsumerRegistrationSchema = z
  .object({
    name: consumerName,
    repoURL: z.string().regex(/^https:\\/\\/[^ ]+\\.git\$/),
    suspended: z.boolean().default(false), // the off state the chart renders
    builds: z.array(z.string()).optional(),
  })
  .superRefine((e, ctx) => {
    const deployGroup = ["chartPath"] as const;
  });
''';

    test('a field declared as a zod type is read with that type', () {
      final List<DeclaredField> found = registrationFieldsIn(schema);

      expect(found.map((DeclaredField each) => '${each.name}=${each.type}'), <String>[
        'name=null',
        'repoURL=string',
        'suspended=boolean',
        'builds=array',
      ]);
      expect(found.first.schema, 'ConsumerRegistrationSchema');
    });

    test('the block ends at its closing brace, so a refinement declares no field', () {
      expect(
        registrationFieldsIn(schema).map((DeclaredField each) => each.name),
        isNot(contains('deployGroup')),
      );
    });

    test('the shorthand that names an imported schema is a field with no readable type', () {
      const String tenant = '''
export const TenantRegistrationSchema = z
  .object({
    subdomain,
    seedUsers: z.boolean().default(false),
  })
''';

      final List<DeclaredField> found = registrationFieldsIn(tenant);

      expect(found.map((DeclaredField each) => each.name), <String>['subdomain', 'seedUsers']);
      expect(found.first.type, isNull);
    });

    test('THE INNOCENT NEIGHBOUR: a schema that is not a registration declares nothing here', () {
      const String other = '''
export const ConsumerManifestSchema = z
  .object({
    suspended: z.string(),
  })
''';

      expect(registrationFieldsIn(other), isEmpty);
    });
  });

  group('what it reports', () {
    const RegistrationSelector suspended = RegistrationSelector(
      appset: 'apps/consumer-build/files/applicationset.yaml',
      glob: 'registrations/*/build.yaml',
      key: 'suspended',
      value: 'false',
      valueIsString: true,
    );
    const List<DeclaredField> declared = <DeclaredField>[
      DeclaredField(schema: 'ConsumerRegistrationSchema', name: 'suspended', type: 'boolean'),
      DeclaredField(schema: 'ConsumerRegistrationSchema', name: 'cluster', type: 'string'),
    ];

    test('the planted innocent: a quoted "false" against a z.boolean() field', () {
      // The answer this check carries: fmt.Sprintf("%v", false) prints `false`
      // (generator_spec_processor.go:134), so the QUOTED selector value is exactly what the boolean
      // reaches the selector as.
      expect(
        auditRegistrationSelectors(selectors: <RegistrationSelector>[suspended], fields: declared),
        isEmpty,
      );
    });

    test('the planted defect: a value no printing of the declared type ever equals', () {
      final List<SelectorFinding> found = auditRegistrationSelectors(
        selectors: <RegistrationSelector>[
          const RegistrationSelector(
            appset: 'apps/consumer-build/files/applicationset.yaml',
            glob: 'registrations/*/build.yaml',
            key: 'suspended',
            value: 'False',
            valueIsString: true,
          ),
        ],
        fields: declared,
      );

      expect(found, hasLength(1));
      expect(found.single.toString(), contains('matches no registration and nothing says so'));
      expect(found.single.toString(), contains('z.boolean()'));
    });

    test('the planted defect: a selector key no registration schema declares', () {
      final List<SelectorFinding> found = auditRegistrationSelectors(
        selectors: <RegistrationSelector>[
          const RegistrationSelector(
            appset: 'apps/consumer-build/files/applicationset.yaml',
            glob: 'registrations/*/build.yaml',
            key: 'suspend',
            value: 'false',
            valueIsString: true,
          ),
        ],
        fields: declared,
      );

      expect(found, hasLength(1));
      expect(found.single.toString(), contains('selector.go:217'));
    });

    test('the planted defect: an unquoted boolean where matchLabels holds strings', () {
      final List<SelectorFinding> found = auditRegistrationSelectors(
        selectors: <RegistrationSelector>[
          const RegistrationSelector(
            appset: 'apps/consumer-build/files/applicationset.yaml',
            glob: 'registrations/*/build.yaml',
            key: 'suspended',
            value: 'false',
            valueIsString: false,
          ),
        ],
        fields: declared,
      );

      expect(found, hasLength(1));
      expect(found.single.toString(), contains('map[string]string'));
    });

    test('the planted defect: a field whose declaration names another schema', () {
      final List<SelectorFinding> found = auditRegistrationSelectors(
        selectors: <RegistrationSelector>[suspended],
        fields: <DeclaredField>[
          const DeclaredField(schema: 'ConsumerRegistrationSchema', name: 'suspended', type: null),
        ],
      );

      expect(found, hasLength(1));
      expect(found.single.toString(), contains('not readable from the declaration'));
    });

    test('the planted innocent: a string field admits the value it is selected by', () {
      expect(
        auditRegistrationSelectors(
          selectors: <RegistrationSelector>[
            const RegistrationSelector(
              appset: 'argocd/apps/consumers-appset.yaml',
              glob: 'registrations/*/prod.yaml',
              key: 'cluster',
              value: 'm1',
              valueIsString: true,
            ),
          ],
          fields: declared,
        ),
        isEmpty,
      );
    });
  });
}

/// Every file of [repository] that carries an ApplicationSet, minus this package and the hidden
/// directories.
///
/// Found by the line the kind stands on rather than by a parse of everything, because most of what
/// this tree holds is Helm templates that are not YAML until they are rendered — and the five that
/// carry an ApplicationSet are plain documents, one of them (`apps/consumer-build/files/`) held
/// outside `templates/` for exactly that reason.
Iterable<File> _applicationSetsOf(Directory repository) sync* {
  for (final FileSystemEntity entry in repository.listSync(followLinks: false)) {
    final String name = p.basename(entry.path);
    if (name.startsWith('.') || name == 'checks') {
      continue;
    }
    if (entry is Directory) {
      for (final FileSystemEntity each in entry.listSync(recursive: true, followLinks: false)) {
        if (each is File && _carriesApplicationSet(each)) {
          yield each;
        }
      }
      continue;
    }
    if (entry is File && _carriesApplicationSet(entry)) {
      yield entry;
    }
  }
}

/// Whether [file] is a YAML document declaring an ApplicationSet.
bool _carriesApplicationSet(File file) {
  if (!file.path.endsWith('.yaml') && !file.path.endsWith('.yml')) {
    return false;
  }
  return file
      .readAsStringSync()
      .split('\n')
      .any((String line) => line.trimRight() == 'kind: ApplicationSet');
}
