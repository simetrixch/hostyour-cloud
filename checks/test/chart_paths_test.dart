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

    test('every generator glob this tree can answer selects at least one tracked file', () {
      final Map<String, String> manifests = _argocdMaterial(repository, tracked);
      expect(manifests, isNotEmpty, reason: 'a check over nothing reads like a pass');

      expect(
        auditGeneratorFiles(
          manifests: manifests,
          tracked: tracked,
          repository: slug,
        ).map((UnresolvedPath each) => each.toString()),
        isEmpty,
      );
      expect(
        auditGeneratorFiles(manifests: manifests, tracked: <String>{}, repository: slug),
        isNotEmpty,
        reason: 'against an empty tree every judged glob must report, or nothing was being judged',
      );
    });

    test('every source directory this tree can answer carries at least one tracked file', () {
      final Map<String, String> manifests = _argocdMaterial(repository, tracked);
      expect(manifests, isNotEmpty, reason: 'a check over nothing reads like a pass');

      expect(
        auditSourcePaths(
          manifests: manifests,
          tracked: tracked,
          repository: slug,
        ).map((UnresolvedPath each) => each.toString()),
        isEmpty,
      );
      expect(
        auditSourcePaths(
          manifests: manifests,
          tracked: <String>{},
          repository: slug,
        ).map((UnresolvedPath each) => each.named),
        containsAll(<String>[
          'units/postgresql',
          'units/mongodb',
          'units/networkpolicy',
          'units/quota',
          'slaves/slave',
        ]),
        reason:
            'the five charts that are not applications are rendered by path alone, so a scan that '
            'stopped reaching them would go on reporting nothing after one of them moved',
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

  group('what makes a generator glob resolve', () {
    // The shape argocd/apps/applicationset.yaml has: a git generator naming this repository, a
    // revision, and the globs it selects files by.
    const String product = 'example/product';
    String generator({
      required List<String> globs,
      String url = 'https://github.com/example/product.git',
      String revision = 'master',
    }) =>
        '  generators:\n'
        '    - git:\n'
        '        repoURL: $url\n'
        '        revision: $revision\n'
        '        files:\n'
        '${globs.map((String each) => '          - path: "$each"\n').join()}';

    test('the planted defect: a glob no tracked file matches', () {
      final List<UnresolvedPath> found = auditGeneratorFiles(
        manifests: <String, String>{
          'argocd/apps/one.yaml': generator(globs: <String>['apps/*/app.yaml']),
        },
        tracked: <String>{'apps/one/Chart.yaml'},
        repository: product,
      );

      expect(found, hasLength(1));
      expect(found.single.named, 'apps/*/app.yaml');
      expect(found.single.toString(), contains('produces zero Applications'));
    });

    test('THE INNOCENT NEIGHBOUR: one tracked file of the shape is enough', () {
      expect(
        auditGeneratorFiles(
          manifests: <String, String>{
            'argocd/apps/one.yaml': generator(globs: <String>['apps/*/app.yaml']),
          },
          tracked: <String>{'apps/one/app.yaml'},
          repository: product,
        ),
        isEmpty,
      );
    });

    test('a single star stops at a slash and a double star crosses it', () {
      expect(
        auditGeneratorFiles(
          manifests: <String, String>{
            'argocd/apps/one.yaml': generator(globs: <String>['apps/*/app.yaml']),
          },
          tracked: <String>{'apps/one/nested/app.yaml'},
          repository: product,
        ),
        hasLength(1),
      );
      expect(
        auditGeneratorFiles(
          manifests: <String, String>{
            'argocd/apps/one.yaml': generator(globs: <String>['apps/**/app.yaml']),
          },
          tracked: <String>{'apps/one/nested/app.yaml'},
          repository: product,
        ),
        isEmpty,
      );
    });

    test('another repository\'s files are not this tree\'s to answer', () {
      expect(
        auditGeneratorFiles(
          manifests: <String, String>{
            'argocd/apps/one.yaml': generator(
              globs: <String>['apps/*/app.yaml'],
              url: 'https://github.com/customer/catalog.git',
            ),
          },
          tracked: <String>{},
          repository: product,
        ),
        isEmpty,
      );
    });

    test('a revision this tree is not carries files this tree cannot answer', () {
      // The slaves generator reads clusters/active/*.yaml on __BOOKS_BRANCH__: nothing of that
      // shape is tracked on master, and reporting it would demand a books file on the trunk.
      expect(
        auditGeneratorFiles(
          manifests: <String, String>{
            'argocd/apps/one.yaml': generator(
              globs: <String>['clusters/active/*.yaml'],
              revision: '__BOOKS_BRANCH__',
            ),
          },
          tracked: <String>{},
          repository: product,
        ),
        isEmpty,
      );
    });
  });

  group('what makes a source directory resolve', () {
    // The shape the appsets have: a values-only ref source, then a chart source naming a directory.
    const String product = 'example/product';
    String sources({required String path, String revision = 'master'}) =>
        '      sources:\n'
        '        - repoURL: &repo "https://github.com/example/product.git"\n'
        '          targetRevision: master\n'
        '          ref: values\n'
        '        - repoURL: *repo\n'
        '          targetRevision: $revision\n'
        '          path: $path\n';

    test('the planted defect: a directory no tracked file stands under', () {
      final List<UnresolvedPath> found = auditSourcePaths(
        manifests: <String, String>{'argocd/apps/one.yaml': sources(path: 'units/quota')},
        tracked: <String>{'units/mongodb/Chart.yaml'},
        repository: product,
      );

      expect(found, hasLength(1));
      expect(found.single.named, 'units/quota');
      expect(found.single.toString(), contains('empty manifest set'));
    });

    test('THE INNOCENT NEIGHBOUR: one tracked file under it is enough', () {
      expect(
        auditSourcePaths(
          manifests: <String, String>{'argocd/apps/one.yaml': sources(path: 'units/quota')},
          tracked: <String>{'units/quota/Chart.yaml'},
          repository: product,
        ),
        isEmpty,
      );
    });

    test('a directory whose name only PREFIXES a tracked one answers nothing', () {
      // units/quo is not units/quota, and a prefix comparison would have called it resolved.
      expect(
        auditSourcePaths(
          manifests: <String, String>{'argocd/apps/one.yaml': sources(path: 'units/quo')},
          tracked: <String>{'units/quota/Chart.yaml'},
          repository: product,
        ),
        hasLength(1),
      );
    });

    test('a values-only source names no directory and is passed over', () {
      expect(
        auditSourcePaths(
          manifests: <String, String>{
            'argocd/apps/one.yaml':
                '      sources:\n'
                '        - repoURL: "https://github.com/example/product.git"\n'
                '          targetRevision: master\n'
                '          ref: values\n',
          },
          tracked: <String>{},
          repository: product,
        ),
        isEmpty,
      );
    });

    test('a path composed at render time cannot be resolved by reading files', () {
      expect(
        auditSourcePaths(
          manifests: <String, String>{'argocd/apps/one.yaml': sources(path: '"{{ .chartPath }}"')},
          tracked: <String>{},
          repository: product,
        ),
        isEmpty,
      );
    });

    test('a revision this tree is not carries a directory this tree cannot answer', () {
      expect(
        auditSourcePaths(
          manifests: <String, String>{
            'argocd/apps/one.yaml': sources(path: 'charts/member', revision: '__BOOKS_BRANCH__'),
          },
          tracked: <String>{},
          repository: product,
        ),
        isEmpty,
      );
    });

    test('a source under the singular source: key is judged like a list item', () {
      // argocd/root-app.yaml is written that way, and it is the one that points ArgoCD at the
      // directory every other manifest of this tree stands in.
      final List<UnresolvedPath> found = auditSourcePaths(
        manifests: <String, String>{
          'argocd/root-app.yaml':
              '  source:\n'
              '    repoURL: https://github.com/example/product.git\n'
              '    targetRevision: master\n'
              '    path: argocd/apps\n',
        },
        tracked: <String>{'argocd/root-app.yaml'},
        repository: product,
      );

      expect(found, hasLength(1));
      expect(found.single.named, 'argocd/apps');
    });
  });
}

/// The ArgoCD material of [repository]: every tracked file under argocd/ by the path it stands at.
Map<String, String> _argocdMaterial(Directory repository, Set<String> tracked) => <String, String>{
  for (final String path in tracked)
    if (path.startsWith('argocd/') && path.endsWith('.yaml'))
      path: File('${repository.path}/$path').readAsStringSync(),
};

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
