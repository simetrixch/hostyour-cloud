import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';

/// appset-cluster-map-keys — over the real trees, and over planted ones.
///
/// **What this is guarding.** `clusters/active/<fqdn>.yaml` is one file read across three
/// repositories: this one's generators select maps by their fields and read fields out of the ones
/// they matched, the deploy programs write a master's map, the Controller writes a slave's.
/// Neither kind of drift fails loudly — a selector that matches nothing produces zero Applications
/// and no error, and a template key no matched map carries ends the whole reconcile under
/// missingkey=error, so not one Application of that set is created.
///
/// **Why nothing here restates a key or a value.** A list written into this suite would be a fourth
/// spelling of the same file, and the drift being watched for could then happen inside the guard.
/// Every side is read where it is decided.
void main() {
  final Directory repository = Directory.current.parent;

  group('the trees as they stand', () {
    test('every appset over the cluster maps reads and selects what a map can carry', () {
      final Directory installation = installationRoot();
      final Directory controller = controllerRoot();

      final String program = File(
        '${installation.path}/$installationPrograms/deploy-branch.yaml',
      ).readAsStringSync();
      final String template = File(
        '${installation.path}/$installationClusterMapTemplate',
      ).readAsStringSync();
      final String marking = File(
        '${controller.path}/$controllerClusterMarking',
      ).readAsStringSync();

      final Set<String> written = clusterMapTemplateKeysIn(template);
      final Set<String> declared = clusterMapSchemaKeysIn(marking);
      final String? directory = clusterMapDirectoryIn(marking);
      final Map<String, String> writtenFrom = clusterMapValueSourcesIn(
        program,
        template: installationClusterMapTemplate,
      );
      final Map<String, String> stampedFrom = stampedMarkersIn(program, tree: generatorTree);
      final Map<String, Set<String>> allowed = allowedAnswerValuesIn(program);

      // A comparison against nothing reads like a pass, which is the failure this whole suite exists
      // to refuse. Every side is asserted present before anything is judged against it.
      expect(
        written,
        isNotEmpty,
        reason: 'the deploy programs\' map template names no key — it was not read',
      );
      expect(
        declared,
        isNotEmpty,
        reason: 'the Controller\'s $clusterMarkingSchemaName declares no key — it was not read',
      );
      expect(
        directory,
        isNotNull,
        reason: 'the Controller declares no $clusterMarkingDirName — it was not read',
      );
      expect(
        writtenFrom,
        isNotEmpty,
        reason: 'no program row renders $installationClusterMapTemplate — it was not read',
      );
      expect(
        stampedFrom,
        isNotEmpty,
        reason: 'the program stamps no marker into the $generatorTree tree — it was not read',
      );
      expect(
        allowed,
        isNotEmpty,
        reason: 'the program closes no answer to a list — it was not read',
      );

      final Map<String, String> appsets = _appsetsOver(repository, directory!);
      expect(
        appsets,
        isNotEmpty,
        reason: 'no appset under argocd/apps selects files under $directory — nothing was read',
      );

      final List<ClusterMapMismatch> found = <ClusterMapMismatch>[
        for (final MapEntry<String, String> each in appsets.entries)
          ...auditClusterMapAppset(
            where: each.key,
            reads: templateKeysReadIn(each.value),
            selects: matchLabelsIn(each.value),
            carried: <String>{...written, ...declared},
            writtenFrom: writtenFrom,
            stampedFrom: stampedFrom,
            allowed: allowed,
          ),
      ];

      expect(found, isEmpty);
    });

    test('WHAT IT DOES NOT REACH: the appsets over the registrations are named, not counted', () {
      // The consumers and tenants appsets read registrations/<unit>/<stage>.yaml, whose only writer
      // is the Controller's registry — not a cluster map and not this check's subject. Naming them
      // here is what keeps a green run from being read as a statement about them.
      final String? directory = clusterMapDirectoryIn(
        File('${controllerRoot().path}/$controllerClusterMarking').readAsStringSync(),
      );
      final Map<String, String> outside = <String, String>{
        for (final File each in _appsetFilesIn(repository))
          if (!_selectsUnder(each.readAsStringSync(), directory!))
            _named(each): generatorFileGlobsIn(each.readAsStringSync()).join(', '),
      };

      expect(
        outside.keys,
        containsAll(<String>['consumers-appset.yaml', 'tenants-appset.yaml']),
        reason:
            'an appset moved into or out of this check\'s reach without the note moving with it',
      );
    });
  });

  group('what it reads out of a file', () {
    test(
      'a template key is read wherever an action stands, and the generator\'s own roots are not',
      () {
        const String appset = '''
    template:
      metadata:
        name: "{{ .values.cluster }}-apps"
      spec:
        source:
          helm:
            valuesObject:
              slave:
                branch: "{{ .fqdn }}"
                masterFqdn: "{{ .master }}"
                guid: "{{ index .path.segments 1 }}"
                short: '{{ index (splitList "." .fqdn) 0 }}'
''';
        expect(templateKeysReadIn(appset), <String>{'fqdn', 'master'});
      },
    );

    test('a hyphenated key is read through index, which is the only form it has', () {
      // SEVEN OF THE FOURTEEN keys a map carries hold a hyphen, and `.books-cluster` is not a name a
      // go template accepts — a hyphen there is subtraction. `index . "books-cluster"` is therefore
      // not a style somebody chose but the only way the file can say it, and a reader blind to it
      // watches half the map while reporting on all of it.
      const String appset = '''
    template:
      spec:
        source:
          helm:
            valuesObject:
              books: '{{ index . "books-cluster" }}'
              plane: '{{ index . `build-plane` }}'
              apex: "{{ index . \\"unit-apex\\" }}"
''';
      expect(templateKeysReadIn(appset), <String>{'books-cluster', 'build-plane', 'unit-apex'});
    });

    test('THE INNOCENT NEIGHBOUR: index into the generator\'s own roots is not a map key', () {
      // `index .path.segments 1` and `index (splitList "." .fqdn) 0` both index something that is
      // not the map, and the map is what this reader is about.
      const String appset = '''
    template:
      spec:
        guid: "{{ index .path.segments 1 }}"
        short: '{{ index (splitList "." .fqdn) 0 }}'
''';
      expect(templateKeysReadIn(appset), <String>{'fqdn'});
    });

    test('THE INNOCENT NEIGHBOUR: a key a comment talks about is prose, not a read', () {
      const String appset = '''
  # It was {{ .master }} until the answer behind it was renamed.
  template:
    spec:
      name: "{{ .fqdn }}"
''';
      expect(templateKeysReadIn(appset), <String>{'fqdn'});
    });

    test('a nested git generator is found — a matrix puts it one level further down', () {
      const String appset = '''
spec:
  generators:
    - matrix:
        generators:
          - git:
              files:
                - path: "registrations/*/dev.yaml"
          - list:
              elementsYaml: "{{ .members | toJson }}"
''';
      expect(generatorFileGlobsIn(appset), <String>{'registrations/*/dev.yaml'});
    });

    test('a selector is read as key and value together', () {
      const String appset = '''
spec:
  generators:
    - git:
        files:
          - path: "clusters/active/*.yaml"
      selector:
        matchLabels:
          role: slave
          stage: __STAGE__
          books-cluster: __BOOKS_BRANCH__
''';
      expect(matchLabelsIn(appset), <String, String>{
        'role': 'slave',
        'stage': '__STAGE__',
        'books-cluster': '__BOOKS_BRANCH__',
      });
    });

    test('the map template names its keys, and its explanation names none', () {
      expect(
        clusterMapTemplateKeysIn('''
# What this cluster is.
#
# fqdn: not a key, a sentence about one.
fqdn: <fqdn>
books-cluster: <books-cluster>
post-url: <post-url?>
'''),
        <String>{'fqdn', 'books-cluster', 'post-url'},
      );
    });

    test('the Controller\'s strict schema names the keys a slave\'s map may carry', () {
      expect(
        clusterMapSchemaKeysIn('''
const ClusterMarkingFileSchema = z.object({
  fqdn: z.string().min(1),
  "books-cluster": z.string().min(1).optional(),
  master: z.string().min(1).optional(),
  apiPort: z.number().int().positive().optional(),
}).strict();
'''),
        <String>{'fqdn', 'books-cluster', 'master', 'apiPort'},
      );
    });

    test('the answer behind each map key comes out of the row that renders the map', () {
      expect(
        clusterMapValueSourcesIn('''
steps:
  - step: write_file_from_template
    template: ansiwise/templates/cluster-map.tpl
    values:
      fqdn: { answer: fqdn }
      books-cluster: { answer: books_cluster }
      alert-recipients: { answer: alert_recipients, join: ", " }
''', template: 'ansiwise/templates/cluster-map.tpl'),
        <String, String>{
          'fqdn': 'fqdn',
          'books-cluster': 'books_cluster',
          'alert-recipients': 'alert_recipients',
        },
      );
    });

    test('a stamp naming no answer of its own falls back to the program\'s default', () {
      expect(
        stampedMarkersIn('''
defaults:
  value_answer: fqdn
steps:
  - step: stamp_placeholder_in_tracked_files
    placeholder: __CLUSTER_HOST__
    tree: argocd
  - step: stamp_placeholder_in_tracked_files
    placeholder: __BOOKS_BRANCH__
    value_answer: books_cluster
    tree: argocd
''', tree: 'argocd'),
        <String, String>{'__CLUSTER_HOST__': 'fqdn', '__BOOKS_BRANCH__': 'books_cluster'},
      );
    });

    test('a stamp taking its value out of a FILE names no answer to be held against', () {
      // The slave branch program stamps the books marker out of the master's own map. That states a
      // fact about one run, not about an answer, and there is nothing on this side to compare it to.
      expect(
        stampedMarkersIn('''
steps:
  - step: stamp_placeholder_in_tracked_files
    placeholder: __BOOKS_BRANCH__
    value_file: /srv/hostyour-cloud-slave-map.yaml
    value_key: books-cluster
    tree: argocd
''', tree: 'argocd'),
        isEmpty,
      );
    });

    test('a stamp outside the generator tree is not one of the generators\' stamps', () {
      expect(
        stampedMarkersIn('''
steps:
  - step: stamp_placeholder_in_tracked_files
    placeholder: __MASTER_NAME__
    value_answer: books_cluster
    tree: bootstrap
''', tree: 'argocd'),
        isEmpty,
      );
    });

    test('an answer with no allowed list is absent, not empty — the two say opposite things', () {
      final Map<String, Set<String>> allowed = allowedAnswerValuesIn('''
answers:
  - name: fqdn
    kind: text
  - name: role
    kind: text
    allowed: [master, slave]
''');
      expect(allowed, <String, Set<String>>{
        'role': <String>{'master', 'slave'},
      });
      expect(allowed.containsKey('fqdn'), isFalse);
    });
  });

  group('what it refuses', () {
    const Set<String> carried = <String>{
      'fqdn',
      'stage',
      'role',
      'books-cluster',
      'master',
      'apiHost',
    };
    const Map<String, String> writtenFrom = <String, String>{
      'fqdn': 'fqdn',
      'stage': 'stage',
      'role': 'role',
      'books-cluster': 'books_cluster',
    };
    const Map<String, String> stampedFrom = <String, String>{
      '__STAGE__': 'stage',
      '__BOOKS_BRANCH__': 'books_cluster',
      '__CLUSTER_HOST__': 'fqdn',
    };
    const Map<String, Set<String>> allowed = <String, Set<String>>{
      'role': <String>{'master', 'slave'},
      'stage': <String>{'dev', 'test', 'prod'},
    };

    List<ClusterMapMismatch> audit({
      Set<String> reads = const <String>{},
      Map<String, String> selects = const <String, String>{},
    }) => auditClusterMapAppset(
      where: 'argocd/apps/slaves-appset.yaml',
      reads: reads,
      selects: selects,
      carried: carried,
      writtenFrom: writtenFrom,
      stampedFrom: stampedFrom,
      allowed: allowed,
    );

    test('THE PLANTED UNKNOWN KEY: a read no writer writes is reported, and the file is named', () {
      final List<ClusterMapMismatch> found = audit(reads: <String>{'fqdn', 'masterFqdn'});

      expect(found, hasLength(1));
      expect(found.single.where, 'argocd/apps/slaves-appset.yaml');
      expect(found.single.what, 'reads the key "masterFqdn"');
      expect(found.single.because, contains('missingkey=error'));
    });

    test('THE INNOCENT NEIGHBOURS: every key a writer writes passes, whichever writer it is', () {
      expect(audit(reads: <String>{'fqdn', 'stage', 'master', 'apiHost'}), isEmpty);
    });

    test('a literal under an answer that is not closed to words can match no map', () {
      // The shape the slaves appset shipped with: a reserved domain standing where an installation's
      // own value belongs, in a file that ships to every installation.
      final List<ClusterMapMismatch> found = audit(
        selects: <String, String>{'books-cluster': 'example.invalid'},
      );

      expect(found, hasLength(1));
      expect(found.single.because, contains('"books_cluster"'));
      expect(found.single.because, contains('zero Applications'));
    });

    test('a marker stamped from ANOTHER answer is reported, and both answers are named', () {
      final List<ClusterMapMismatch> found = audit(
        selects: <String, String>{'books-cluster': '__CLUSTER_HOST__'},
      );

      expect(found, hasLength(1));
      expect(found.single.because, contains('"fqdn"'));
      expect(found.single.because, contains('"books_cluster"'));
    });

    test('a marker no program stamps into the generator tree reaches a cluster as itself', () {
      final List<ClusterMapMismatch> found = audit(
        selects: <String, String>{'books-cluster': '__BOOKS_CLUSTER__'},
      );

      expect(found, hasLength(1));
      expect(found.single.because, contains('no branch program stamps that marker'));
    });

    test('a selector on a key no writer writes is reported too', () {
      final List<ClusterMapMismatch> found = audit(
        selects: <String, String>{'booksCluster': '__BOOKS_BRANCH__'},
      );

      expect(found, hasLength(1));
      expect(
        found.single.because,
        contains('no writer of a cluster map writes a key of that name'),
      );
    });

    test(
      'a selector on a key only the CONTROLLER writes cannot be held against a branch stamp',
      () {
        final List<ClusterMapMismatch> found = audit(
          selects: <String, String>{'master': '__BOOKS_BRANCH__'},
        );

        expect(found, hasLength(1));
        expect(found.single.because, contains('the deploy programs write no such key'));
      },
    );

    test('THE INNOCENT NEIGHBOURS: the selector as it must stand passes whole', () {
      expect(
        audit(
          reads: <String>{'fqdn', 'stage', 'master', 'apiHost'},
          selects: <String, String>{
            'role': 'slave',
            'stage': '__STAGE__',
            'books-cluster': '__BOOKS_BRANCH__',
          },
        ),
        isEmpty,
      );
    });
  });
}

/// Every appset file under `argocd/apps`.
List<File> _appsetFilesIn(Directory repository) => <File>[
  for (final FileSystemEntity each in Directory('${repository.path}/argocd/apps').listSync())
    if (each is File && each.path.endsWith('.yaml')) each,
];

/// Whether [appset] selects files under [directory].
bool _selectsUnder(String appset, String directory) =>
    generatorFileGlobsIn(appset).any((String glob) => glob.startsWith('$directory/'));

/// The appsets that read cluster maps, keyed by the path a report names.
Map<String, String> _appsetsOver(Directory repository, String directory) {
  final Map<String, String> found = <String, String>{};
  for (final File each in _appsetFilesIn(repository)) {
    final String content = each.readAsStringSync();
    if (_selectsUnder(content, directory)) {
      found['argocd/apps/${_named(each)}'] = content;
    }
  }
  return found;
}

String _named(File file) => file.path.split(RegExp(r'[\\/]')).last;
