import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';

/// chart-paths — over the real tree, and over planted ones.
///
/// **Why both sides come from git, never from the file system.** The tree the cluster reads is a
/// fresh clone, so what exists there is what `git ls-files` answers: a path spelled in the wrong
/// case resolves on this machine's case-insensitive checkout and fails on the cluster, and an
/// uncommitted file exists here and nowhere else. The repository's own identity comes from its
/// remote for the same reason a name is not written here — the check knows the tool, not one
/// repository's name.
void main() {
  final Directory repository = Directory.current.parent;
  final Set<String> tracked = _git(repository, <String>['ls-files']).toSet();
  final String slug = repositorySlug(
    _git(repository, <String>['remote', 'get-url', 'origin']).single,
  );

  group('the tree as it stands', () {
    test('every file:// dependency resolves to a tracked chart of the matching name', () {
      final Map<String, String> charts = <String, String>{
        for (final String path in tracked)
          if (path == 'Chart.yaml' || path.endsWith('/Chart.yaml'))
            path: File('${repository.path}/$path').readAsStringSync(),
      };
      expect(charts, isNotEmpty, reason: 'a check over nothing reads like a pass');

      expect(
        auditChartDependencies(
          charts: charts,
          tracked: tracked,
        ).map((UnresolvedPath each) => each.toString()),
        isEmpty,
      );
    });

    test('every valueFile the argocd material must carry resolves or is declared deliberate', () {
      final Map<String, String> manifests = <String, String>{
        for (final String path in tracked)
          if (path.startsWith('argocd/') && path.endsWith('.yaml'))
            path: File('${repository.path}/$path').readAsStringSync(),
      };
      expect(manifests, isNotEmpty, reason: 'a check over nothing reads like a pass');

      expect(
        auditValueFiles(
          manifests: manifests,
          tracked: tracked,
          repository: slug,
        ).map((UnresolvedPath each) => each.toString()),
        isEmpty,
      );
    });
  });

  group('what makes a dependency resolve', () {
    const String depending =
        'name: one\n'
        'dependencies:\n'
        '  - name: common\n'
        '    repository: file://../../charts/common\n';

    test('the planted defect: a file:// repository where no Chart.yaml is tracked', () {
      final List<UnresolvedPath> found = auditChartDependencies(
        charts: <String, String>{'apps/one/Chart.yaml': depending},
        tracked: <String>{'apps/one/Chart.yaml'},
      );

      expect(found, hasLength(1));
      expect(found.single.origin, 'apps/one/Chart.yaml');
      expect(found.single.toString(), contains('charts/common/Chart.yaml'));
      expect(found.single.toString(), contains('fresh clone'));
    });

    test('the planted innocent: a dependency the tracked tree answers', () {
      expect(
        auditChartDependencies(
          charts: <String, String>{
            'apps/one/Chart.yaml': depending,
            'charts/common/Chart.yaml': 'name: common\n',
          },
          tracked: <String>{'apps/one/Chart.yaml', 'charts/common/Chart.yaml'},
        ),
        isEmpty,
      );
    });

    test('a spelling this file system resolves and git does not is still unresolved', () {
      // The defect the issue opens with: charts/Common resolves on a case-insensitive checkout and
      // fails on the cluster. Judging against the TRACKED path is what catches it here.
      final List<UnresolvedPath> found = auditChartDependencies(
        charts: <String, String>{
          'apps/one/Chart.yaml': depending.replaceFirst('charts/common', 'charts/Common'),
          'charts/common/Chart.yaml': 'name: common\n',
        },
        tracked: <String>{'apps/one/Chart.yaml', 'charts/common/Chart.yaml'},
      );

      expect(found, hasLength(1));
      expect(found.single.toString(), contains('charts/Common/Chart.yaml'));
    });

    test('a dependency whose name the chart there does not carry', () {
      final List<UnresolvedPath> found = auditChartDependencies(
        charts: <String, String>{
          'apps/one/Chart.yaml': depending,
          'charts/common/Chart.yaml': 'name: shared\n',
        },
        tracked: <String>{'apps/one/Chart.yaml', 'charts/common/Chart.yaml'},
      );

      expect(found, hasLength(1));
      expect(found.single.toString(), contains('"shared"'));
      expect(found.single.toString(), contains('"common"'));
    });

    test('a dependency reaching outside the tree', () {
      final List<UnresolvedPath> found = auditChartDependencies(
        charts: <String, String>{
          'apps/one/Chart.yaml':
              'name: one\ndependencies:\n'
              '  - name: common\n    repository: file://../../../elsewhere/common\n',
        },
        tracked: <String>{'apps/one/Chart.yaml'},
      );

      expect(found, hasLength(1));
      expect(found.single.toString(), contains('outside the tree'));
    });

    test('a remote repository is not this tree\'s to answer', () {
      expect(
        auditChartDependencies(
          charts: <String, String>{
            'apps/one/Chart.yaml':
                'name: one\ndependencies:\n'
                '  - name: argo-cd\n    repository: https://argoproj.github.io/argo-helm\n',
          },
          tracked: <String>{'apps/one/Chart.yaml'},
        ),
        isEmpty,
      );
    });
  });

  group('what makes a valueFile deliberate', () {
    // The shape the appsets under argocd/ have: a values-only ref source, then a chart source whose
    // helm block names the list. The repository under audit is a placeholder, as the ref name is.
    const String product = 'example/product';
    String manifest({required List<String> entries, bool flag = false, String path = 'apps/one'}) =>
        '      sources:\n'
        '        - repoURL: &repo "https://github.com/example/product.git"\n'
        '          targetRevision: master\n'
        '          ref: values\n'
        '        - repoURL: *repo\n'
        '          targetRevision: master\n'
        '          path: $path\n'
        '          helm:\n'
        '            valueFiles:\n'
        '${entries.map((String each) => '              - $each\n').join()}'
        '${flag ? '            ignoreMissingValueFiles: true\n' : ''}';

    test('the planted defect: a valueFile nothing carries and no flag speaks for', () {
      final List<UnresolvedPath> found = auditValueFiles(
        manifests: <String, String>{
          'argocd/apps/one.yaml': manifest(entries: <String>['values-common.yaml']),
        },
        tracked: <String>{'apps/one/Chart.yaml'},
        repository: product,
      );

      expect(found, hasLength(1));
      expect(found.single.toString(), contains('apps/one/values-common.yaml'));
      expect(found.single.toString(), contains('nothing declares its absence deliberate'));
    });

    test('the planted innocent: the same absence WITH the flag is a design, not a defect', () {
      expect(
        auditValueFiles(
          manifests: <String, String>{
            'argocd/apps/one.yaml': manifest(entries: <String>['values-common.yaml'], flag: true),
          },
          tracked: <String>{'apps/one/Chart.yaml'},
          repository: product,
        ),
        isEmpty,
      );
    });

    test(r'the flag cannot make a $-ref path into this repository deliberate', () {
      // The audit tenants-appset.yaml's comment names as lost: this tree is the only place the
      // path could exist, so under the flag the file simply never loads, silently.
      final List<UnresolvedPath> found = auditValueFiles(
        manifests: <String, String>{
          'argocd/apps/one.yaml': manifest(
            entries: <String>[r'$values/platform/values-common.yaml'],
            flag: true,
          ),
        },
        tracked: <String>{'apps/one/Chart.yaml'},
        repository: product,
      );

      expect(found, hasLength(1));
      expect(found.single.toString(), contains('platform/values-common.yaml'));
      expect(found.single.toString(), contains('can never load'));
    });

    test(r'a $-ref path the tree answers is quiet, flag or no flag', () {
      expect(
        auditValueFiles(
          manifests: <String, String>{
            'argocd/apps/one.yaml': manifest(
              entries: <String>[r'$values/platform/values-common.yaml'],
              flag: true,
            ),
          },
          tracked: <String>{'platform/values-common.yaml'},
          repository: product,
        ),
        isEmpty,
      );
    });

    test(r'a $-ref that no source carries resolves nowhere, flag or no flag', () {
      final List<UnresolvedPath> found = auditValueFiles(
        manifests: <String, String>{
          'argocd/apps/one.yaml': manifest(entries: <String>[r'$pins/one/pin.yaml'], flag: true),
        },
        tracked: <String>{'apps/one/Chart.yaml'},
        repository: product,
      );

      expect(found, hasLength(1));
      expect(found.single.toString(), contains('ref: pins'));
    });

    test('another repository\'s file is not this tree\'s to answer', () {
      final String foreign = manifest(
        entries: <String>['values-common.yaml'],
      ).replaceFirst('- repoURL: *repo', '- repoURL: "https://github.com/customer/member.git"');
      expect(
        auditValueFiles(
          manifests: <String, String>{'argocd/apps/one.yaml': foreign},
          tracked: <String>{'apps/one/Chart.yaml'},
          repository: product,
        ),
        isEmpty,
      );
    });

    test('a path composed at render time cannot be resolved by reading files', () {
      expect(
        auditValueFiles(
          manifests: <String, String>{
            'argocd/apps/one.yaml': manifest(
              entries: <String>[
                'values-size-{{ .size }}.yaml',
                r'$values/cluster/{{ .name }}.yaml',
              ],
            ),
          },
          tracked: <String>{'apps/one/Chart.yaml'},
          repository: product,
        ),
        isEmpty,
      );
    });

    test('a stamp marker is a wildcard: any tracked file of the shape answers it', () {
      final Map<String, String> manifests = <String, String>{
        'argocd/apps/one.yaml': manifest(entries: <String>['values-__STAGE__.yaml']),
      };

      expect(
        auditValueFiles(
          manifests: manifests,
          tracked: <String>{'apps/one/values-dev.yaml'},
          repository: product,
        ),
        isEmpty,
      );
      expect(
        auditValueFiles(manifests: manifests, tracked: <String>{}, repository: product),
        hasLength(1),
        reason: 'the wildcard forgives the stamped value, never the whole family being gone',
      );
    });
  });
}

/// Runs git with [arguments] in [repository] and answers its stdout lines.
List<String> _git(Directory repository, List<String> arguments) {
  final ProcessResult result = Process.runSync(
    'git',
    arguments,
    workingDirectory: repository.path,
    runInShell: Platform.isWindows,
  );
  if (result.exitCode != 0) {
    throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
  }
  return (result.stdout as String)
      .split('\n')
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty)
      .toList();
}
