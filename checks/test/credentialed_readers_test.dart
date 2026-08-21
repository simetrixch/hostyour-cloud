import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// credentialed-readers — over the real tree, and over planted ones.
///
/// **Why the planted defects are whole env LISTS and not single values.** Three of the five shapes
/// this check reports are about the RELATION between two entries — one holding the URI, one filling
/// the variable it reads — and one of those three is about the ORDER they stand in. A probe that
/// planted a lone value could not go red on any of them, and the check would still report finding
/// nothing.
void main() {
  final Directory repository = Directory.current.parent;

  /// Every env list under `apps/`, `slaves/` and `units/`, by the path it stands at.
  List<EnvList> treeEnvLists() {
    final List<EnvList> lists = <EnvList>[];
    for (final String top in <String>['apps', 'slaves', 'units']) {
      final Directory root = Directory('${repository.path}/$top');
      if (!root.existsSync()) {
        continue;
      }
      for (final FileSystemEntity each in root.listSync(recursive: true)) {
        if (each is! File || !each.uri.pathSegments.last.startsWith('values')) {
          continue;
        }
        if (!each.path.endsWith('.yaml')) {
          continue;
        }
        final String relative = each.path
            .substring(repository.path.length + 1)
            .replaceAll(r'\', '/');
        lists.addAll(envListsIn(where: relative, values: loadYaml(each.readAsStringSync())));
      }
    }
    return lists;
  }

  group('the tree as it stands', () {
    test(
      'every connection URI in an env list of this repository carries a Secret-backed password',
      () {
        expect(
          auditCredentialedReaders(
            lists: treeEnvLists(),
          ).map((CredentialFinding each) => each.toString()),
          isEmpty,
        );
      },
    );

    test('HOW MUCH IT COVERS: the readers it found are named, not counted', () {
      // A check that only asserted "nothing is wrong" would go on passing after the last reader
      // left the tree, and green would then mean nobody was looking. Naming them makes a reader
      // added or removed red until somebody says so on purpose.
      final Set<String> found = <String>{
        for (final EnvList list in treeEnvLists())
          for (final EnvEntry entry in list.entries)
            if (entry.value != null && readerUriIn(entry.value!) != null)
              '${list.where} ${entry.name}',
      };

      expect(found, <String>{
        'apps/dbgate/values-common.yaml URL_mongo',
        'apps/dbgate/values-common.yaml URL_redis',
      }, reason: 'these are the connection URIs this repository writes into a pod environment');
    });
  });

  group('what a value is', () {
    test('a password written as a variable is read as the variable it names', () {
      final ReaderUri? uri = readerUriIn(
        r'redis://default:$(REDIS_DEFAULT_PW)@$(SLAVE_ADDRESS):6379',
      );

      expect(uri?.scheme, 'redis');
      expect(uri?.credential, 'REDIS_DEFAULT_PW');
      expect(uri?.literal, isFalse);
    });

    test('a URI with no userinfo carries no credential', () {
      final ReaderUri? uri = readerUriIn(r'redis://$(SLAVE_ADDRESS):6379');

      expect(uri?.scheme, 'redis');
      expect(uri?.credential, isNull);
      expect(uri?.literal, isFalse);
    });

    test(
      'a user with no password is read as no credential, because the server refuses it alike',
      () {
        expect(readerUriIn('mongodb://root@host:27017')?.credential, isNull);
      },
    );

    test('a password written out is read as a literal', () {
      expect(readerUriIn('mongodb://root:hunter2@host:27017/?authSource=admin')?.literal, isTrue);
    });

    test('THE INNOCENT NEIGHBOUR: a scheme whose server authenticates nobody is not a reader', () {
      // The value that made this distinction necessary: the mail relay and the identity provider
      // are both dialled by URI out of an env list, and neither takes a password in it.
      expect(readerUriIn('http://postfix.postfix.svc.cluster.local:25'), isNull);
      expect(readerUriIn('smtp://postfix:25'), isNull);
    });

    test('THE INNOCENT NEIGHBOUR: a plain address is not a URI', () {
      expect(readerUriIn('redis-dev.redis.svc.cluster.local'), isNull);
      expect(readerUriIn('100.64.0.11'), isNull);
    });
  });

  group('what an env list holds', () {
    test('an env list is found wherever it stands, and its order is kept', () {
      final List<EnvList> lists = envListsIn(
        where: 'values.yaml',
        values: loadYaml('''
app:
  env:
    - name: SLAVE_ADDRESS
      value: "100.64.0.11"
    - name: MONGO_ROOT_PW
      valueFrom:
        secretKeyRef:
          name: dbgate-db-credentials
          key: mongodb-password
    - name: URL_mongo
      value: "mongodb://root:\$(MONGO_ROOT_PW)@\$(SLAVE_ADDRESS):27017"
'''),
      );

      expect(lists, hasLength(1));
      expect(lists.single.entries.map((EnvEntry each) => each.name), <String>[
        'SLAVE_ADDRESS',
        'MONGO_ROOT_PW',
        'URL_mongo',
      ]);
      expect(lists.single.entries[1].fromSecret, isTrue);
      expect(lists.single.entries[1].value, isNull);
      expect(lists.single.entries[0].fromSecret, isFalse);
    });

    test('THE INNOCENT NEIGHBOUR: the platform-wide global.env string is no env list', () {
      // `global.env` carries "dev"/"test"/"prod", and a reader that took it for a container's env
      // list would report a defect in every values file of the tree.
      expect(envListsIn(where: 'values.yaml', values: loadYaml('global:\n  env: dev\n')), isEmpty);
    });
  });

  group('what it reports', () {
    EnvList planted(List<EnvEntry> entries) => EnvList(where: 'planted.yaml', entries: entries);

    const EnvEntry address = EnvEntry(
      name: 'SLAVE_ADDRESS',
      value: '100.64.0.11',
      fromSecret: false,
    );
    const EnvEntry secret = EnvEntry(name: 'REDIS_DEFAULT_PW', fromSecret: true);

    test('THE INNOCENT: the arrangement as it must stand', () {
      expect(
        auditCredentialedReaders(
          lists: <EnvList>[
            planted(<EnvEntry>[
              address,
              secret,
              const EnvEntry(
                name: 'URL_redis',
                value: r'redis://default:$(REDIS_DEFAULT_PW)@$(SLAVE_ADDRESS):6379',
                fromSecret: false,
              ),
            ]),
          ],
        ),
        isEmpty,
      );
    });

    test('THE INNOCENT NEIGHBOUR: an env list with no connection URI is judged on nothing', () {
      expect(
        auditCredentialedReaders(
          lists: <EnvList>[
            planted(<EnvEntry>[
              const EnvEntry(name: 'SKIP_ALL_AUTH', value: 'true', fromSecret: false),
              const EnvEntry(name: 'CONNECTIONS', value: 'mongo,redis', fromSecret: false),
            ]),
          ],
        ),
        isEmpty,
      );
    });

    test('THE PLANTED DEFECT: the reader with no credential, which is what #64 was about', () {
      final List<CredentialFinding> found = auditCredentialedReaders(
        lists: <EnvList>[
          planted(<EnvEntry>[
            address,
            const EnvEntry(
              name: 'URL_redis',
              value: r'redis://$(SLAVE_ADDRESS):6379',
              fromSecret: false,
            ),
          ]),
        ],
      );

      expect(found.single, isA<UncredentialedReader>());
      expect(found.single.entry, 'URL_redis');
      expect(found.single.toString(), contains('refuses the connection at authentication'));
    });

    test('THE PLANTED DEFECT: the password written out in the values file', () {
      final List<CredentialFinding> found = auditCredentialedReaders(
        lists: <EnvList>[
          planted(<EnvEntry>[
            const EnvEntry(
              name: 'URL_mongo',
              value: 'mongodb://root:hunter2@host:27017/?authSource=admin',
              fromSecret: false,
            ),
          ]),
        ],
      );

      expect(found.single, isA<LiteralCredential>());
      expect(found.single.toString(), contains('in git'));
    });

    test('THE PLANTED DEFECT: a variable no entry of the list declares', () {
      final List<CredentialFinding> found = auditCredentialedReaders(
        lists: <EnvList>[
          planted(<EnvEntry>[
            address,
            const EnvEntry(
              name: 'URL_redis',
              value: r'redis://default:$(REDIS_PW)@$(SLAVE_ADDRESS):6379',
              fromSecret: false,
            ),
          ]),
        ],
      );

      expect(found.single, isA<UnfilledCredential>());
      expect(found.single.toString(), contains('leaves an unresolvable'));
    });

    test('THE PLANTED DEFECT: the variable declared AFTER the URI that reads it', () {
      // The one the tree already knew about — apps/dbgate/values-common.yaml says it twice in prose —
      // and the one no diff shows, because both entries are present and correct.
      final List<CredentialFinding> found = auditCredentialedReaders(
        lists: <EnvList>[
          planted(<EnvEntry>[
            address,
            const EnvEntry(
              name: 'URL_redis',
              value: r'redis://default:$(REDIS_DEFAULT_PW)@$(SLAVE_ADDRESS):6379',
              fromSecret: false,
            ),
            secret,
          ]),
        ],
      );

      expect(found.single, isA<LateCredential>());
      expect(found.single.toString(), contains('only from entries before'));
    });

    test('THE PLANTED DEFECT: the variable filled from this file rather than from a Secret', () {
      final List<CredentialFinding> found = auditCredentialedReaders(
        lists: <EnvList>[
          planted(<EnvEntry>[
            address,
            const EnvEntry(name: 'REDIS_DEFAULT_PW', value: 'hunter2', fromSecret: false),
            const EnvEntry(
              name: 'URL_redis',
              value: r'redis://default:$(REDIS_DEFAULT_PW)@$(SLAVE_ADDRESS):6379',
              fromSecret: false,
            ),
          ]),
        ],
      );

      expect(found.single, isA<UnbackedCredential>());
      expect(found.single.toString(), contains('one more indirection'));
    });

    test('the five shapes are five findings, not one', () {
      final List<CredentialFinding> found = auditCredentialedReaders(
        lists: <EnvList>[
          planted(<EnvEntry>[
            const EnvEntry(name: 'A', value: 'redis://host:6379', fromSecret: false),
          ]),
          planted(<EnvEntry>[
            const EnvEntry(name: 'B', value: 'redis://default:pw@host:6379', fromSecret: false),
          ]),
          planted(<EnvEntry>[
            const EnvEntry(
              name: 'C',
              value: r'redis://default:$(NOPE)@host:6379',
              fromSecret: false,
            ),
          ]),
          planted(<EnvEntry>[
            const EnvEntry(
              name: 'D',
              value: r'redis://default:$(LATE)@host:6379',
              fromSecret: false,
            ),
            const EnvEntry(name: 'LATE', fromSecret: true),
          ]),
          planted(<EnvEntry>[
            const EnvEntry(name: 'PLAIN', value: 'pw', fromSecret: false),
            const EnvEntry(
              name: 'E',
              value: r'redis://default:$(PLAIN)@host:6379',
              fromSecret: false,
            ),
          ]),
        ],
      );

      expect(found.map((CredentialFinding each) => each.runtimeType.toString()), <String>[
        'UncredentialedReader',
        'LiteralCredential',
        'UnfilledCredential',
        'LateCredential',
        'UnbackedCredential',
      ]);
    });
  });
}
