import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';

/// external-secret-keys — over the real tree, and over planted ones.
///
/// **Why the first group asserts what was JUDGED before it asserts what was FOUND.** This check
/// holds a narrow set: seven Secrets of the thirty this tree declares, the ones whose only
/// readers here name them key by key. An empty finding list is what a run says when it judged
/// nothing at all, so the run states which Secrets it held to the rule and which it passed over,
/// one by one and by name. A Secret that leaves the judged set — because somebody mounted it as a
/// volume, or gave its target a template — turns that assertion red until somebody writes down
/// that it left.
void main() {
  final Directory repository = Directory.current.parent;

  group('the tree as it stands', () {
    late final List<DeclaredSecret> declared;
    late final List<SecretKeyReference> read;
    late final List<String> rest;
    late final int secretKeyLines;

    setUpAll(() {
      declared = <DeclaredSecret>[];
      read = <SecretKeyReference>[];
      rest = <String>[];
      int lines = 0;
      for (final String path in _trackedYaml(repository)) {
        final String source = File('${repository.path}/$path').readAsStringSync();
        lines += commentFreeLines(source).where(_secretKeyLine.hasMatch).length;
        final SecretFileReading reading = readSecretFile(path: path, source: source);
        declared.addAll(reading.declared);
        read.addAll(reading.read);
        rest.addAll(reading.rest);
      }
      secretKeyLines = lines;
    });

    test('every key the reader could not place would be a key it stopped seeing', () {
      // The one way this check could quietly stop covering its subject: an ExternalSecret written
      // in a shape the reader no longer recognises declares keys nobody counts, and the run stays
      // green because green is what "found nothing" looks like. Every `- secretKey:` line the tree
      // writes outside a comment belongs to exactly one declaration, so the two totals are the
      // same number or the reader has lost a block.
      expect(
        declared.fold<int>(0, (int all, DeclaredSecret each) => all + each.keys.length) +
            declared.fold<int>(0, (int all, DeclaredSecret each) => all + each.unreadableKeys),
        secretKeyLines,
        reason:
            'the tree writes $secretKeyLines `- secretKey:` lines and the reader placed '
            '${declared.length} declarations',
      );
    });

    test('how far a rule demanding a secretKeyRef per key would overshoot, in numbers', () {
      // The three numbers the library doc comment states about why this check is narrow. Written
      // down in prose they are a stale line anchor waiting to happen; asserted here they cannot
      // drift without the gate saying so.
      final Map<String, Set<String>> keys = <String, Set<String>>{};
      for (final DeclaredSecret each in declared) {
        if (each.secret case final String secret) {
          keys.putIfAbsent(secret, () => <String>{}).addAll(each.keys);
        }
      }
      final Map<String, Set<String>> named = <String, Set<String>>{};
      for (final SecretKeyReference each in read) {
        named.putIfAbsent(each.secret, () => <String>{}).add(each.key);
      }
      final int declaredKeys = keys.values.fold(
        0,
        (int all, Set<String> each) => all + each.length,
      );
      final int namedKeys = keys.entries.fold(
        0,
        (int all, MapEntry<String, Set<String>> each) =>
            all + each.value.where((String key) => named[each.key]?.contains(key) ?? false).length,
      );

      expect(keys, hasLength(32), reason: 'the Secrets this tree declares and can name');
      expect(declaredKeys, 50, reason: 'the keys those declarations carry');
      expect(namedKeys, 14, reason: 'the keys a secretKeyRef of this tree names');
      expect(
        declaredKeys - namedKeys,
        36,
        reason: 'what a rule demanding a secretKeyRef per declared key would report unread',
      );
    });

    test('every key of a Secret this tree reads key by key is a key it reads', () {
      final KeyAudit audit = auditExternalSecretKeys(
        declared: declared,
        read: read,
        namedElsewhere: namedTokensIn(rest),
      );

      // WHAT THIS RUN COVERED, written out rather than counted.
      expect(audit.judged, <String>{
        'dbgate-db-credentials',
        'dbgate-redis-credentials',
        'manager-app',
        'manager-cloudflare-dns',
        'manager-deploy-repo-pat',
        'manager-github',
        'manager-storage-box',
        'manager-webhook',
      }, reason: 'these are the Secrets this tree reads only one key at a time');

      // AND WHAT IT DID NOT, one by one rather than counted, with the reason beside each in
      // `audit.passedOver`. A Secret that moves between the two sets makes one of these red.
      expect(audit.passedOver.keys.toSet(), <String>{
        'build-git-https',
        'build-npmrc',
        'bump-git-https',
        'charts/external-secret/templates/externalsecret.yaml',
        'cluster-slave',
        'gate-runner-registry-pull',
        'grafana-admin-credentials',
        'idp-oidc-grafana',
        'image-builder-registry-pull',
        'image-builder-registry-push',
        'image-builder-webhook-secrets',
        'manager-master-key',
        'manager-registry-pull',
        'mongodb-credentials',
        'obs-push-htpasswd',
        'observability-agent-push-credentials',
        'postfix-dkim-key',
        'postgresql-credentials',
        'redis-credentials',
        'registry-pull-source',
        'registry-reaper-push',
        'repo-catalog',
        'repo-platform',
        'zot-htpasswd',
        'zot-sync-credentials',
      }, reason: 'these are the Secrets whose key set this repository cannot decide by itself');

      expect(
        audit.findings.map((KeyFinding each) => each.toString()),
        isEmpty,
        reason: 'a key declared and unread, or read and undeclared, in the tree as it stands',
      );
    });

    test(
      'THE PLANTED DEFECT: hostyour-cloud#62, the sudo password projected back into manager-app',
      () {
        // The removal this check was built beside (264fe3b) took this block out of
        // apps/manager/templates/externalsecret-app.yaml. It goes back in here as the TEXT it was,
        // read by the same reader that reads the tree, and judged against the real readers of
        // manager-app — so what goes red is the file the ticket is about and not a fixture.
        //
        // `rest` is reused unchanged: every planted line falls inside the ExternalSecret document,
        // and the reader removes that document whole before anything is scanned for a name.
        const String path = 'apps/manager/templates/externalsecret-app.yaml';
        final String source =
            '${File('${repository.path}/$path').readAsStringSync()}'
            '    # THE PASSWORD THAT RAISES A COMMAND TO ROOT on the machine this runs on, written\n'
            '    # into the same entry by the seed.\n'
            '    - secretKey: sudo-password\n'
            '      remoteRef:\n'
            '        key: {{ printf "%s/app/manager" .Values.global.env }}\n'
            '        property: sudo-password\n'
            '        conversionStrategy: Default\n'
            '        decodingStrategy: None\n'
            '        metadataPolicy: None\n'
            '        nullBytePolicy: Ignore\n';
        final SecretFileReading planted = readSecretFile(path: path, source: source);
        expect(planted.declared.single.keys, <String>{'oidc-client-secret', 'sudo-password'});

        final KeyAudit audit = auditExternalSecretKeys(
          declared: <DeclaredSecret>[
            for (final DeclaredSecret each in declared)
              if (each.where != path) each,
            ...planted.declared,
          ],
          read: read,
          namedElsewhere: namedTokensIn(rest),
        );

        expect(audit.judged, contains('manager-app'));
        expect(audit.findings.single, isA<UnreadKey>());
        expect(
          audit.findings.single.toString(),
          contains('declares key "sudo-password" of Secret "manager-app"'),
        );
      },
    );

    test('THE PLANTED DEFECT: a reader of manager-app that spells the key one letter wrong', () {
      final KeyAudit audit = auditExternalSecretKeys(
        declared: declared,
        read: <SecretKeyReference>[
          ...read,
          const SecretKeyReference(
            secret: 'manager-app',
            key: 'oidc-client-secrets',
            where: 'apps/manager/templates/deployment.yaml',
          ),
        ],
        namedElsewhere: namedTokensIn(rest),
      );

      expect(audit.findings.single, isA<UndeclaredKey>());
      expect(audit.findings.single.toString(), contains('CreateContainerConfigError'));
    });
  });

  group('what a declaration says', () {
    const String template = '''
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: manager-app
spec:
  target:
    name: manager-app
    creationPolicy: Owner
  data:
    - secretKey: oidc-client-secret
      remoteRef:
        key: dev/app/manager
        property: oidc-client-secret
''';

    test('the target Secret it writes and the keys it declares', () {
      final SecretFileReading reading = readSecretFile(path: 'apps/x.yaml', source: template);

      expect(reading.declared.single.secret, 'manager-app');
      expect(reading.declared.single.keys, <String>{'oidc-client-secret'});
      expect(reading.declared.single.templated, isFalse);
      expect(reading.declared.single.unreadableKeys, 0);
      expect(reading.declared.single.where, 'apps/x.yaml');
    });

    test('a target carrying a template is a target whose keys are the template\'s', () {
      // apps/manager/templates/externalsecret-registry.yaml declares `user` and `pass` and writes
      // `.dockerconfigjson`: a check that demanded a secretKeyRef for `user` would refuse a chart
      // that is correct, and a false refusal costs the same trust as a false pass.
      final SecretFileReading reading = readSecretFile(
        path: 'apps/x.yaml',
        source: template.replaceFirst(
          '    creationPolicy: Owner\n',
          '    creationPolicy: Owner\n'
              '    template:\n'
              '      engineVersion: v2\n'
              '      data:\n'
              '        .dockerconfigjson: |-\n'
              '          {"auths":{}}\n',
        ),
      );

      expect(reading.declared.single.templated, isTrue);
      expect(reading.declared.single.keys, <String>{'oidc-client-secret'});
    });

    test('a name the template composes is a name this tree cannot read', () {
      final SecretFileReading reading = readSecretFile(
        path: 'charts/external-secret/templates/externalsecret.yaml',
        source: template.replaceFirst(
          '  target:\n    name: manager-app\n',
          '  target:\n    name: {{ .Values.externalSecret.targetSecretName }}\n',
        ),
      );

      expect(reading.declared.single.secret, isNull);
    });

    test('a key the template composes is counted, not silently dropped', () {
      // apps/consumer-build/templates/externalsecret-npmrc.yaml ranges over a list of properties.
      // Passing the entry over without counting it would make an unreadable declaration look like
      // a declaration of nothing, which is exactly the state a green run must not describe.
      final SecretFileReading reading = readSecretFile(
        path: 'apps/x.yaml',
        source: template.replaceFirst(
          '    - secretKey: oidc-client-secret\n',
          '    - secretKey: {{ \$prop }}\n',
        ),
      );

      expect(reading.declared.single.keys, isEmpty);
      expect(reading.declared.single.unreadableKeys, 1);
    });

    test('two documents in one file are two declarations', () {
      final SecretFileReading reading = readSecretFile(
        path: 'apps/x.yaml',
        source: '$template---\n${template.replaceAll('manager-app', 'manager-github')}',
      );

      expect(reading.declared.map((DeclaredSecret each) => each.secret), <String>[
        'manager-app',
        'manager-github',
      ]);
    });

    test('THE INNOCENT NEIGHBOUR: the CRD that DESCRIBES an ExternalSecret declares none', () {
      // apps/external-secrets/templates/crd-externalsecret.yaml carries the word secretKey and the
      // words `kind: ExternalSecret`, both indented, because it is the schema of the thing rather
      // than one of them.
      final SecretFileReading reading = readSecretFile(
        path: 'apps/external-secrets/templates/crd-externalsecret.yaml',
        source:
            'apiVersion: apiextensions.k8s.io/v1\n'
            'kind: CustomResourceDefinition\n'
            'spec:\n'
            '  names:\n'
            '    kind: ExternalSecret\n'
            '  versions:\n'
            '    - schema:\n'
            '        properties:\n'
            '          secretKey:\n'
            '            type: string\n',
      );

      expect(reading.declared, isEmpty);
    });
  });

  group('what a values file says', () {
    const String values = '''
externalsecret-mongodb:
  externalSecret:
    enabled: true
    name: mongodb-credentials
    namespace: mongodb
    targetSecretName: mongodb-credentials
    data:
      - secretKey: root-password
        property: mongodb-root-password
      - secretKey: keyfile
        property: mongodb-replica-set-key
''';

    test('the target Secret and the keys are read out of the block that renders them', () {
      final SecretFileReading reading = readSecretFile(
        path: 'apps/mongodb/values-common.yaml',
        source: values,
      );

      expect(reading.declared.single.secret, 'mongodb-credentials');
      expect(reading.declared.single.keys, <String>{'root-password', 'keyfile'});
    });

    test('metadata.name is NOT the target Secret, and a block without one is unreadable', () {
      // charts/external-secret/templates/externalsecret.yaml defaults the target to
      // `common.fullname`, not to the ExternalSecret's own metadata.name, so reading the name here
      // would state a Secret this chart does not write.
      final SecretFileReading reading = readSecretFile(
        path: 'apps/mongodb/values-common.yaml',
        source: values.replaceFirst('    targetSecretName: mongodb-credentials\n', ''),
      );

      expect(reading.declared.single.secret, isNull);
      expect(reading.declared.single.keys, <String>{'root-password', 'keyfile'});
    });

    test('THE INNOCENT NEIGHBOUR: a per-stage override layer declares nothing', () {
      // Every app repeats its externalSecret block in values-dev/test/prod carrying the one field
      // that differs — vaultPath. Counted as declarations, those would be three more Secrets
      // nobody can name, in the list this check prints about its own reach.
      final SecretFileReading reading = readSecretFile(
        path: 'apps/mongodb/values-dev.yaml',
        source:
            'externalsecret-mongodb:\n'
            '  externalSecret:\n'
            '    vaultPath: dev/app/mongodb\n',
      );

      expect(reading.declared, isEmpty);
    });
  });

  group('what a workload reads', () {
    test('the Secret and the key are read out of the secretKeyRef block', () {
      final SecretFileReading reading = readSecretFile(
        path: 'apps/manager/templates/deployment.yaml',
        source:
            'spec:\n'
            '  containers:\n'
            '    - env:\n'
            '        - name: OIDC_CLIENT_SECRET\n'
            '          valueFrom:\n'
            '            secretKeyRef:\n'
            '              name: manager-app\n'
            '              key: oidc-client-secret\n'
            '        - name: GITHUB_WRITE_PAT\n'
            '          valueFrom:\n'
            '            secretKeyRef:\n'
            '              name: manager-github\n'
            '              key: write-pat\n',
      );

      expect(reading.read.map((SecretKeyReference each) => '${each.secret}/${each.key}'), <String>[
        'manager-app/oidc-client-secret',
        'manager-github/write-pat',
      ]);
      expect(reading.rest.where((String each) => each.contains('manager-app')), isEmpty);
    });

    test('THE INNOCENT NEIGHBOUR: an envFrom names the Secret and no key of it', () {
      // The line stays in `rest`, which is what takes image-builder-registry-pull out of the
      // judged set: its two keys travel as environment variables named by the Secret's own keys.
      final SecretFileReading reading = readSecretFile(
        path: 'apps/consumer-build/templates/pipeline-release.yaml',
        source:
            'steps:\n'
            '  - envFrom:\n'
            '      - secretRef:\n'
            '          name: image-builder-registry-pull\n',
      );

      expect(reading.read, isEmpty);
      expect(namedTokensIn(reading.rest), contains('image-builder-registry-pull'));
    });
  });

  group('what a comment does not say', () {
    test('a name written in a YAML comment is not the tree naming the Secret', () {
      // This is what decides how much the check covers. apps/manager/templates/deployment.yaml
      // names manager-storage-box, manager-webhook and manager-cloudflare-dns in the comments over
      // the env vars that read them, and counting those as consumption would pass over nearly
      // every Secret this check exists to judge.
      expect(
        namedTokensIn(
          commentFreeLines(
            '# Sourced from the manager-storage-box Secret.\n'
            'value: /etc/manager  # and from manager-webhook\n',
          ),
        ),
        isNot(anyOf(contains('manager-storage-box'), contains('manager-webhook'))),
      );
    });

    test('a Helm comment block is a comment however many lines it runs over', () {
      // apps/service-provisioner/templates/rbac.yaml opens with one of these, and it names
      // mongodb-credentials and postgresql-credentials in prose.
      expect(
        namedTokensIn(
          commentFreeLines(
            '{{- /*\n'
            'It may READ the backend admin credentials (mongodb/mongodb-credentials).\n'
            '*/ -}}\n'
            'kind: ClusterRole\n',
          ),
        ),
        <String>{'kind', 'ClusterRole'},
      );
    });

    test('a hash inside a quoted scalar opens no comment', () {
      expect(
        namedTokensIn(commentFreeLines('  property: "pull # password"\n')),
        contains('password'),
      );
    });

    test('a Helm comment blanks its lines rather than removing them', () {
      // The readers below it work by indentation, so a stripper that shortened the file would move
      // every block after it.
      const String source = 'a\n{{/*\nb\n*/}}\nc\n';
      expect(commentFreeLines(source), hasLength(source.split('\n').length));
      expect(commentFreeLines(source), <String>['a', '', '', '', 'c', '']);
    });
  });

  group('what it reports', () {
    const DeclaredSecret plain = DeclaredSecret(
      secret: 'manager-app',
      keys: <String>{'oidc-client-secret'},
      templated: false,
      unreadableKeys: 0,
      where: 'apps/manager/templates/externalsecret-app.yaml',
    );
    const SecretKeyReference reads = SecretKeyReference(
      secret: 'manager-app',
      key: 'oidc-client-secret',
      where: 'apps/manager/templates/deployment.yaml',
    );

    test('THE INNOCENT: every key declared is a key read', () {
      final KeyAudit audit = auditExternalSecretKeys(
        declared: <DeclaredSecret>[plain],
        read: <SecretKeyReference>[reads],
        namedElsewhere: <String>{},
      );

      expect(audit.judged, <String>{'manager-app'});
      expect(audit.findings, isEmpty);
    });

    test('the planted defect: a declared key no secretKeyRef names', () {
      final KeyAudit audit = auditExternalSecretKeys(
        declared: <DeclaredSecret>[
          const DeclaredSecret(
            secret: 'manager-app',
            keys: <String>{'oidc-client-secret', 'sudo-password'},
            templated: false,
            unreadableKeys: 0,
            where: 'apps/manager/templates/externalsecret-app.yaml',
          ),
        ],
        read: <SecretKeyReference>[reads],
        namedElsewhere: <String>{},
      );

      expect(audit.findings.single, isA<UnreadKey>());
      expect(audit.findings.single.key, 'sudo-password');
      expect(
        audit.findings.single.toString(),
        contains('counted by nobody as a credential in use'),
      );
    });

    test('the planted defect: a secretKeyRef naming a key the declaration does not carry', () {
      final KeyAudit audit = auditExternalSecretKeys(
        declared: <DeclaredSecret>[plain],
        read: <SecretKeyReference>[
          reads,
          const SecretKeyReference(
            secret: 'manager-app',
            key: 'sudo-password',
            where: 'apps/manager/templates/deployment.yaml',
          ),
        ],
        namedElsewhere: <String>{},
      );

      expect(audit.findings.single, isA<UndeclaredKey>());
      expect(audit.findings.single.key, 'sudo-password');
    });

    test('the undeclared key is reported even where the Secret is taken whole', () {
      // The mirror finding is wider than the rule above it on purpose: a creationPolicy Owner
      // ExternalSecret with no template owns the whole key set of its Secret, so a reference to a
      // key it does not carry is wrong however the rest of that Secret travels.
      final KeyAudit audit = auditExternalSecretKeys(
        declared: <DeclaredSecret>[
          const DeclaredSecret(
            secret: 'mongodb-credentials',
            keys: <String>{'root-password', 'keyfile'},
            templated: false,
            unreadableKeys: 0,
            where: 'apps/mongodb/values-common.yaml',
          ),
        ],
        read: <SecretKeyReference>[
          const SecretKeyReference(
            secret: 'mongodb-credentials',
            key: 'root-passwords',
            where: 'apps/mongodb/templates/statefulset.yaml',
          ),
        ],
        namedElsewhere: <String>{'mongodb-credentials'},
      );

      expect(audit.judged, isEmpty);
      expect(audit.findings.single, isA<UndeclaredKey>());
    });

    test('two files declaring one name are one judgement, never both verdicts at once', () {
      // apps/mongodb/values-common.yaml and units/mongodb/values.yaml both write
      // mongodb-credentials, and apps/postfix writes postfix-dkim-key once per stage. Judged one
      // declaration at a time, a name could stand in `judged` and in `passedOver` together, and the
      // run would say both that it was held to the rule and that it was not.
      final KeyAudit audit = auditExternalSecretKeys(
        declared: <DeclaredSecret>[
          plain,
          const DeclaredSecret(
            secret: 'manager-app',
            keys: <String>{'sudo-password'},
            templated: false,
            unreadableKeys: 0,
            where: 'apps/x.yaml',
          ),
        ],
        read: <SecretKeyReference>[reads],
        namedElsewhere: <String>{},
      );

      expect(audit.judged, <String>{'manager-app'});
      expect(audit.passedOver, isEmpty);
      expect(audit.findings.single.key, 'sudo-password');
      expect(
        audit.findings.single.toString(),
        startsWith('apps/manager/templates/externalsecret-app.yaml, apps/x.yaml'),
      );
    });

    test(
      'THE INNOCENT NEIGHBOUR: a Secret the tree names outside a secretKeyRef is passed over',
      () {
        final KeyAudit audit = auditExternalSecretKeys(
          declared: <DeclaredSecret>[
            const DeclaredSecret(
              secret: 'manager-master-key',
              keys: <String>{'ssh-private-key', 'host-key-fp'},
              templated: false,
              unreadableKeys: 0,
              where: 'apps/manager/templates/manager-host-secret.yaml',
            ),
          ],
          read: <SecretKeyReference>[
            const SecretKeyReference(
              secret: 'manager-master-key',
              key: 'host-key-fp',
              where: 'apps/manager/templates/deployment.yaml',
            ),
          ],
          namedElsewhere: <String>{'manager-master-key'},
        );

        expect(audit.judged, isEmpty);
        expect(audit.findings, isEmpty);
        expect(
          audit.passedOver['manager-master-key'],
          contains('its keys travel in a shape this check does not model'),
        );
      },
    );

    test('THE INNOCENT NEIGHBOUR: a templated target is passed over with its reason', () {
      final KeyAudit audit = auditExternalSecretKeys(
        declared: <DeclaredSecret>[
          const DeclaredSecret(
            secret: 'manager-registry-pull',
            keys: <String>{'user', 'pass'},
            templated: true,
            unreadableKeys: 0,
            where: 'apps/manager/templates/externalsecret-registry.yaml',
          ),
        ],
        read: <SecretKeyReference>[],
        namedElsewhere: <String>{},
      );

      expect(audit.judged, isEmpty);
      expect(audit.findings, isEmpty);
      expect(audit.passedOver['manager-registry-pull'], contains("template's own"));
    });

    test('THE INNOCENT NEIGHBOUR: a Secret nothing here reads key by key is passed over', () {
      final KeyAudit audit = auditExternalSecretKeys(
        declared: <DeclaredSecret>[
          const DeclaredSecret(
            secret: 'image-builder-webhook-secrets',
            keys: <String>{'github'},
            templated: false,
            unreadableKeys: 0,
            where: 'apps/image-builder/values-common.yaml',
          ),
        ],
        read: <SecretKeyReference>[],
        namedElsewhere: <String>{},
      );

      expect(audit.judged, isEmpty);
      expect(audit.findings, isEmpty);
      expect(
        audit.passedOver['image-builder-webhook-secrets'],
        contains('no secretKeyRef of this tree names it'),
      );
    });

    test('a declaration whose keys are unreadable is passed over, never called complete', () {
      final KeyAudit audit = auditExternalSecretKeys(
        declared: <DeclaredSecret>[
          const DeclaredSecret(
            secret: 'build-npmrc',
            keys: <String>{},
            templated: false,
            unreadableKeys: 1,
            where: 'apps/consumer-build/templates/externalsecret-npmrc.yaml',
          ),
        ],
        read: <SecretKeyReference>[
          const SecretKeyReference(
            secret: 'build-npmrc',
            key: 'npmrc',
            where: 'apps/consumer-build/templates/pipeline-release.yaml',
          ),
        ],
        namedElsewhere: <String>{},
      );

      expect(audit.judged, isEmpty);
      expect(audit.findings, isEmpty);
      expect(audit.passedOver['build-npmrc'], contains('template expression'));
    });
  });
}

final RegExp _secretKeyLine = RegExp(r'^\s*-\s+secretKey:');

/// Every tracked YAML file of [repository] outside this package, as repository-relative paths.
///
/// From git rather than from the file system, for the reason `chart_paths_test.dart` reads it
/// there: what a cluster renders is a fresh clone, and an untracked file is not in it.
List<String> _trackedYaml(Directory repository) {
  final ProcessResult listed = Process.runSync('git', <String>[
    'ls-files',
  ], workingDirectory: repository.path);
  if (listed.exitCode != 0) {
    throw StateError('git ls-files failed: ${listed.stderr}');
  }
  return (listed.stdout as String)
      .split('\n')
      .map((String each) => each.trim())
      .where((String each) => each.endsWith('.yaml') || each.endsWith('.yml'))
      .where((String each) => !each.startsWith('checks/'))
      .toList();
}
