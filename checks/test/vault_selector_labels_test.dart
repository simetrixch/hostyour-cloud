import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// vault-selector-labels — over the real trees, and over planted ones.
///
/// **Why both sides are read and neither may be missing.** The two selectors this check was built
/// after were each sound on their own and dead against the charts, and the guard that existed stood
/// where the material it judges was not. So the suite refuses over an unfindable installation and
/// refuses over an empty side, instead of passing because it found nothing to compare.
///
/// **What is not proven here**, and it is the one shape a planted tree cannot carry: the refusal
/// when there is no installation at all. That answer is only reached after the walk has passed
/// every directory up to the root of the volume, and what stands up there belongs to the machine
/// rather than to this suite. The environment override is the other one: it is read from the
/// process, which a test in the same process cannot set.
void main() {
  final Directory repository = Directory.current.parent;

  group('the trees as they stand', () {
    test('every selector key the deploy programs write is a label key this repository sets', () {
      final Set<String> labelKeys = <String>{};
      for (final File each in _chartMaterialOf(repository)) {
        labelKeys.addAll(chartLabelKeysIn(each.readAsStringSync()));
      }
      expect(labelKeys, isNotEmpty, reason: 'a comparison against no labels reads like a pass');

      final Directory installation = installationRoot();
      final List<VaultSelector> selectors = <VaultSelector>[];
      for (final FileSystemEntity each in Directory(
        '${installation.path}/$installationPrograms',
      ).listSync(recursive: true, followLinks: false)) {
        if (each is! File || !_isYaml(each.path)) {
          continue;
        }
        selectors.addAll(
          vaultSelectorsIn(
            program: p.relative(each.path, from: installation.path),
            document: loadYaml(each.readAsStringSync()),
          ),
        );
      }
      expect(
        selectors,
        isNotEmpty,
        reason:
            'no program of ${installation.path} writes a Vault namespace selector — over nothing '
            'to hold to the labels, a green here would say nothing, and saying nothing green is '
            'the failure this check exists to refuse',
      );

      expect(
        auditVaultSelectorLabels(
          selectors: selectors,
          labelKeys: labelKeys,
        ).map((DeadSelectorKey each) => each.toString()),
        isEmpty,
      );
    });
  });

  group('what a selector names', () {
    test(
      'the keys are read out of the body a program hands Vault, folded and escaped as written',
      () {
        // The shape the programs really write: a `>-` folded scalar whose lines join into one JSON
        // object, with the selector escaped inside it. Read through the same YAML parse the suite
        // uses, so the folding and the escaping are proven and not assumed.
        const String program = r'''
program:
  - step: vault_auth_role
    role: unit-eso
    body: >-
      {"bound_service_account_names":["external-secrets-sa"],
      "bound_service_account_namespace_selector":"{\"matchLabels\":{\"left/unit\":\"true\"}}",
      "token_policies":["<name>-read"],"ttl":"24h"}
''';
        final List<VaultSelector> found = vaultSelectorsIn(
          program: 'programs/one.yaml',
          document: loadYaml(program),
        );

        expect(found, hasLength(1));
        expect(found.single.role, 'unit-eso');
        expect(found.single.key, 'left/unit');
      },
    );

    test('a body binding by namespace list rather than by selector names no key', () {
      // The other shape the programs write, and it is innocent here: an explicit namespace list is
      // held to what exists by Vault itself, not by a label anything has to set.
      final List<VaultSelector> found = vaultSelectorsIn(
        program: 'programs/one.yaml',
        document: <String, Object?>{
          'role': 'platform-eso',
          'body': '{"bound_service_account_namespaces":["one","two"]}',
        },
      );

      expect(found, isEmpty);
    });

    test('a matchExpressions key is a key the selector matches by', () {
      final List<VaultSelector> found = vaultSelectorsIn(
        program: 'programs/one.yaml',
        document: <String, Object?>{
          'role': 'unit-eso',
          'body':
              r'{"bound_service_account_namespace_selector":'
              r'"{\"matchExpressions\":[{\"key\":\"left/unit\",\"operator\":\"Exists\"}]}"}',
        },
      );

      expect(found.map((VaultSelector each) => each.key), <String>['left/unit']);
    });

    test('a selector that cannot be read is an error naming the program, never a pass', () {
      expect(
        () => vaultSelectorsIn(
          program: 'programs/one.yaml',
          document: <String, Object?>{
            'role': 'unit-eso',
            'body': 'bound_service_account_namespace_selector but no JSON around it',
          },
        ),
        throwsA(
          isA<FormatException>().having(
            (FormatException refused) => refused.message,
            'message',
            contains('programs/one.yaml'),
          ),
        ),
      );
    });
  });

  group('what the charts set', () {
    test('the keys under a labels: block are read, wherever the block stands', () {
      // The block scalar shape: the lines sit inside a templatePatch string a generator renders,
      // which is why the reading is over lines and not over a parsed document.
      const String template = '''
  templatePatch: |
    spec:
      syncPolicy:
        managedNamespaceMetadata:
          labels:
            left/unit: "true"
            left/unit-name: "{{ .name }}"
''';

      expect(chartLabelKeysIn(template), <String>{'left/unit', 'left/unit-name'});
    });

    test('THE INNOCENT NEIGHBOUR: matchLabels keys are not read, selecting is not setting', () {
      // Counting a selected key as a set one would let two selectors of the same misspelling prove
      // each other, which is the false green this check exists against.
      const String template = '''
spec:
  podSelector:
    matchLabels:
      left/unit: "true"
''';

      expect(chartLabelKeysIn(template), isEmpty);
    });

    test('a key a template computes is passed over, and its static neighbours still count', () {
      // What `{{ \$k }}` renders ranges over data this check cannot see, and a key it cannot see is
      // not one it may count as set — a selector resting on it is reported, not assumed to match.
      const String template = '''
labels:
  left/unit: "true"
  {{- range \$k, \$v := .extra }}
  {{ \$k }}: {{ \$v | quote }}
  {{- end }}
''';

      expect(chartLabelKeysIn(template), <String>{'left/unit'});
    });

    test('the block ends where the indentation returns', () {
      const String template = '''
metadata:
  labels:
    left/unit: "true"
  annotations:
    note: "not a label"
''';

      expect(chartLabelKeysIn(template), <String>{'left/unit'});
    });
  });

  group('what it reports', () {
    test('the planted defect: a selector key nothing sets', () {
      final List<DeadSelectorKey> found = auditVaultSelectorLabels(
        selectors: <VaultSelector>[
          const VaultSelector('programs/one.yaml', 'unit-eso', 'retired/unit'),
        ],
        labelKeys: <String>{'left/unit'},
      );

      expect(found, hasLength(1));
      expect(found.single.selector.key, 'retired/unit');
      expect(found.single.toString(), contains('matches no namespace'));
    });

    test('the planted innocent: a selector key the charts set', () {
      expect(
        auditVaultSelectorLabels(
          selectors: <VaultSelector>[
            const VaultSelector('programs/one.yaml', 'unit-eso', 'left/unit'),
          ],
          labelKeys: <String>{'left/unit'},
        ),
        isEmpty,
      );
    });
  });

  group('where the programs stand', () {
    late Directory workspace;

    setUp(() {
      // Under the system temporary directory rather than beside the repository, so nothing the
      // search walks past belongs to this checkout.
      workspace = Directory.systemTemp.createTempSync('installation-search');
      addTearDown(() => workspace.deleteSync(recursive: true));
    });

    Directory planted(String path) =>
        Directory('${workspace.path}/$path')..createSync(recursive: true);

    Directory installationAt(String path) {
      planted('$path/$installationPrograms');
      return Directory('${workspace.path}/$path');
    }

    test('a checkout standing beside the repository the suite runs in is found', () {
      final Directory installation = installationAt('checkout');

      expect(
        p.normalize(installationFoundFrom(planted('repository/checks')).path),
        p.normalize(installation.path),
      );
    });

    test('a checkout one directory further out is found, where grouped checkouts put it', () {
      final Directory installation = installationAt('group-b/checkout');

      expect(
        p.normalize(installationFoundFrom(planted('group-a/repository')).path),
        p.normalize(installation.path),
      );
    });

    test('a tree without the layout is passed over, however it is named', () {
      planted('group-a/checkout');
      final Directory installation = installationAt('group-b/checkout');

      expect(
        p.normalize(installationFoundFrom(planted('group-a/repository')).path),
        p.normalize(installation.path),
      );
    });

    test('two trees under the same directory are refused, and both are named', () {
      final Directory one = installationAt('group-b/checkout');
      final Directory other = installationAt('group-c/checkout');

      expect(
        () => installationFoundFrom(planted('group-a/repository')),
        throwsA(
          isA<StateError>()
              .having(
                (StateError refused) => refused.message,
                'message',
                contains(p.normalize(one.path)),
              )
              .having(
                (StateError refused) => refused.message,
                'message',
                contains(p.normalize(other.path)),
              )
              // Reading one of the two would be a choice nobody made, reported as a fact.
              .having(
                (StateError refused) => refused.message,
                'message',
                contains(installationVariable),
              ),
        ),
      );
    });
  });
}

/// Whether the file at [path] is one the chart material is written in.
bool _isYaml(String path) =>
    path.endsWith('.yaml') || path.endsWith('.yml') || path.endsWith('.tpl');

/// Every file of [repository] a label could be set in — the whole tree, minus this package and the
/// hidden directories.
///
/// The whole tree rather than a listed set of directories, because a hand-kept directory list is
/// the same second truth as a hand-kept key list: the day the labels move, the check goes on
/// reading where they were. This package's own tree is left out so a fixture in a probe is never
/// counted as a label the charts set.
Iterable<File> _chartMaterialOf(Directory repository) sync* {
  for (final FileSystemEntity entry in repository.listSync(followLinks: false)) {
    final String name = p.basename(entry.path);
    if (name.startsWith('.') || name == 'checks') {
      continue;
    }
    if (entry is File) {
      if (_isYaml(entry.path)) {
        yield entry;
      }
      continue;
    }
    if (entry is Directory) {
      for (final FileSystemEntity each in entry.listSync(recursive: true, followLinks: false)) {
        if (each is File && _isYaml(each.path) && !each.path.split(p.separator).contains('.git')) {
          yield each;
        }
      }
    }
  }
}
