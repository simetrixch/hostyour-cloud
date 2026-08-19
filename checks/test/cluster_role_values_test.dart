import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';

/// cluster-role-values — over the real trees, and over planted ones.
///
/// **What this is guarding.** The role a cluster carries is one identity across a repository
/// boundary: the installation states it as an answer and stamps it into the app generator's
/// selector, this repository writes it into every `apps/<name>/app.yaml` as `runsOn:`. When the two
/// disagree the generator matches nothing — and an ApplicationSet that matches nothing produces zero
/// Applications and no error. The cluster runs, ArgoCD reports green, and nothing is deployed.
///
/// **Why nothing here restates the role values.** A list written into this suite would be a third
/// spelling of the same identity, and the drift being watched for could then happen inside the
/// guard. Both ends are read where they are decided.
void main() {
  final Directory repository = Directory.current.parent;

  group('the trees as they stand', () {
    test(
      'every runsOn is a value the app generator can match, and every selected role is one a cluster may carry',
      () {
        final RunsOnSelector selector = runsOnSelectorIn(
          File('${repository.path}/argocd/apps/applicationset.yaml').readAsStringSync(),
        );
        final Set<String> allowed = allowedRolesIn(
          File(
            '${installationRoot().path}/$installationPrograms/deploy-branch.yaml',
          ).readAsStringSync(),
        );

        // A comparison against nothing reads like a pass, which is the failure this whole suite exists
        // to refuse. Both ends are asserted present before anything is judged against them.
        expect(
          selector.literals,
          isNotEmpty,
          reason: 'the app generator names no literal it admits — the selector was not read',
        );
        expect(
          selector.stampedRole,
          isTrue,
          reason:
              'the selector no longer defers to the stamped role, and this check assumes it does',
        );
        expect(allowed, isNotEmpty, reason: 'the deploy-branch program declares no allowed role');

        final Map<String, String> runsOn = _runsOnOf(repository);
        final Map<String, String> selected = _selectedRolesOf(repository);
        expect(runsOn, isNotEmpty, reason: 'no app manifest declares runsOn — nothing was read');
        expect(selected, isNotEmpty, reason: 'no generator selects on a role — nothing was read');

        expect(
          auditClusterRoleValues(
            runsOn: runsOn,
            selectedRoles: selected,
            selector: selector,
            allowedRoles: allowed,
          ),
          isEmpty,
        );
      },
    );
  });

  group('what it reads out of a file', () {
    test('a role: that is not a generator selector is not a cluster role', () {
      // The word names several unrelated things in this tree — a Vault auth role under
      // auth.kubernetes above all — and reading every role: line reported those as broken cluster
      // roles. This is that case, verbatim in shape.
      const String generator = '''
spec:
  provider:
    vault:
      auth:
        kubernetes:
          mountPath: kubernetes-__CLUSTER__
          role: external-secrets
''';
      expect(selectedRolesIn(generator), isEmpty);
    });

    test('THE INNOCENT NEIGHBOUR: a role inside matchLabels IS one', () {
      const String generator = '''
      selector:
        matchLabels:
          role: slave
          stage: dev
''';
      expect(selectedRolesIn(generator), <String>{'slave'});
    });

    test(
      'the placeholder is not a value — it stands for whichever role a branch is stamped with',
      () {
        final RunsOnSelector selector = runsOnSelectorIn('''
      selector:
        matchExpressions:
          - key: runsOn
            operator: In
            values:
              - every-cluster
              - __CLUSTER_ROLE__
''');
        expect(selector.literals, <String>{'every-cluster'});
        expect(selector.stampedRole, isTrue);
      },
    );

    test('the allowed roles come out of the answer that is stamped, not out of prose', () {
      expect(
        allowedRolesIn('''
answers:
  - name: fqdn
    kind: text
  - name: role
    kind: text
    allowed: [master, slave]
    describes: >-
      Whether this cluster holds the master part.
'''),
        <String>{'master', 'slave'},
      );
    });
  });

  group('what it refuses', () {
    const RunsOnSelector selector = (literals: <String>{'every-cluster'}, stampedRole: true);
    const Set<String> allowed = <String>{'master', 'slave'};

    test('a runsOn no selector can match is reported, and the file is named', () {
      final List<UnmatchableRole> found = auditClusterRoleValues(
        runsOn: <String, String>{'apps/manager/app.yaml': 'keeps-books'},
        selectedRoles: const <String, String>{},
        selector: selector,
        allowedRoles: allowed,
      );

      expect(found, hasLength(1));
      expect(found.single.where, 'apps/manager/app.yaml');
      expect(found.single.value, 'keeps-books');
      expect(found.single.because, contains('"master", "slave"'));
    });

    test('THE INNOCENT NEIGHBOURS: every value the two ends do admit passes', () {
      expect(
        auditClusterRoleValues(
          runsOn: <String, String>{
            'apps/a/app.yaml': 'every-cluster',
            'apps/b/app.yaml': 'master',
            'apps/c/app.yaml': 'slave',
          },
          selectedRoles: const <String, String>{'slaves-appset.yaml': 'slave'},
          selector: selector,
          allowedRoles: allowed,
        ),
        isEmpty,
      );
    });

    test(
      'a generator selecting a role no cluster may carry is reported too — the same defect from the other end',
      () {
        final List<UnmatchableRole> found = auditClusterRoleValues(
          runsOn: const <String, String>{},
          selectedRoles: <String, String>{'argocd/apps/slaves-appset.yaml': 'reads-books'},
          selector: selector,
          allowedRoles: allowed,
        );

        expect(found, hasLength(1));
        expect(found.single.because, contains('no cluster map will hold'));
      },
    );

    test('a selector closed to its literals admits no role at all', () {
      // The shape a rename leaves behind if somebody takes the placeholder out: every app that names
      // a role stops matching, and there is no error anywhere.
      expect(
        auditClusterRoleValues(
          runsOn: <String, String>{'apps/manager/app.yaml': 'master'},
          selectedRoles: const <String, String>{},
          selector: (literals: const <String>{'every-cluster'}, stampedRole: false),
          allowedRoles: allowed,
        ),
        hasLength(1),
      );
    });
  });
}

/// Every `runsOn:` the app manifests declare, keyed by the path a report names.
Map<String, String> _runsOnOf(Directory repository) {
  final Map<String, String> found = <String, String>{};
  for (final FileSystemEntity each in Directory('${repository.path}/apps').listSync()) {
    final File manifest = File('${each.path}/app.yaml');
    if (manifest.existsSync()) {
      if (runsOnIn(manifest.readAsStringSync()) case final String value) {
        found['apps/${_leafOf(each.path)}/app.yaml'] = value;
      }
    }
  }
  return found;
}

/// Every role a generator selects on, keyed by the file it stands in.
Map<String, String> _selectedRolesOf(Directory repository) {
  final Map<String, String> found = <String, String>{};
  for (final FileSystemEntity each in Directory('${repository.path}/argocd/apps').listSync()) {
    if (each is File && each.path.endsWith('.yaml')) {
      for (final String role in selectedRolesIn(each.readAsStringSync())) {
        found['argocd/apps/${_leafOf(each.path)}'] = role;
      }
    }
  }
  return found;
}

String _leafOf(String path) => path.split(RegExp(r'[\\/]')).last;
