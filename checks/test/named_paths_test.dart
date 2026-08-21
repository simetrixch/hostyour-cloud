import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';

/// named-paths — over the real tree, and over planted ones.
///
/// **What this is guarding.** A comment that names a file is the only map most of this tree has.
/// When the file moves and the sentence does not, the sentence keeps reading as an instruction and
/// nothing fails — a comment renders nowhere. Two families were standing when this was written:
/// eleven places naming `installation/apps/<app>.yaml`, a per-branch deploy toggle that does not
/// exist, and twenty-five naming `argocd/<stage>/apps/*.yaml`, the three per-stage trees that became
/// one. One of the twenty-five was a live shell glob deriving which tenants a release reaches: it
/// matched nothing, its own `[ -f ]` guard stepped over it, and the reach came out empty and green.
///
/// **Why the tracked tree and not the file system.** What a cluster reads is a fresh clone, so a
/// path exists exactly when `git ls-files` answers with it.
void main() {
  final Directory repository = Directory.current.parent;

  group('the tree as it stands', () {
    test('every path this repository names is one it carries or declares absent', () {
      final Set<String> tracked = _tracked(repository);
      final Set<String> tops = <String>{
        for (final String each in tracked)
          if (each.contains('/')) each.split('/').first,
      };
      final Set<String> declaredAbsent = declaredAbsentIn(
        File('${repository.path}/branch-classes.yaml').readAsStringSync(),
        sections: _absenceSections,
      );

      // A comparison against nothing reads like a pass, which is the failure this whole package
      // exists to refuse. Both ends are asserted present before anything is judged against them.
      expect(tracked, isNotEmpty, reason: 'git ls-files answered nothing — the tree was not read');
      expect(tops, isNotEmpty, reason: 'the tracked tree has no top-level directory');
      expect(
        declaredAbsent,
        isNotEmpty,
        reason:
            'branch-classes.yaml declares no path absent — the ${_absenceSections.join(' and ')} '
            'sections were not read, and every path that legitimately stands off the trunk would '
            'be reported',
      );

      final Map<String, Set<String>> named = _namedPathsOf(repository, tracked, tops);
      expect(named, isNotEmpty, reason: 'no tracked file names a path — nothing was read');

      expect(
        auditNamedPaths(named: named, tracked: tracked, declaredAbsent: declaredAbsent),
        isEmpty,
      );
    });
  });

  group('what it reads out of a file', () {
    const Set<String> tops = <String>{'apps', 'argocd', 'installation'};

    test('a path of another tree is not this repository to answer for', () {
      // Both are named all over this tree and neither is ours. They fall out on the first segment,
      // which is what keeps a list of foreign repository names from having to be kept here.
      expect(
        namedPathsIn(
          'see hostyour-manager/shared/branches.ts and ansiwise/programs/deploy-branch.yaml',
          topLevelDirectories: tops,
        ),
        isEmpty,
      );
    });

    test('THE INNOCENT NEIGHBOUR: a path whose first segment IS ours is read', () {
      expect(
        namedPathsIn('loaded after argocd/apps/applicationset.yaml', topLevelDirectories: tops),
        <String>{'argocd/apps/applicationset.yaml'},
      );
    });

    test('a dotted word that is not a path is not read as one', () {
      // A domain, a version and a bare file name each carry a dot, and a reader that took every
      // dotted word would report all three as missing files.
      expect(
        namedPathsIn(
          'the placeholder example.invalid, prometheus-operator v0.92.0, values-common.yaml',
          topLevelDirectories: tops,
        ),
        isEmpty,
      );
    });

    test('a suffix this tree does not carry is not a path', () {
      expect(
        namedPathsIn('apps/registry/config.png', topLevelDirectories: tops),
        isEmpty,
        reason: 'the suffix list is closed on purpose',
      );
    });

    test('a line anchor after a path does not stop the path being read', () {
      expect(
        namedPathsIn(
          'apps/consumer-build/templates/pipeline-release.yaml:806-810 commits the tag',
          topLevelDirectories: tops,
        ),
        <String>{'apps/consumer-build/templates/pipeline-release.yaml'},
      );
    });
  });

  group('what a declaration of absence is read out of', () {
    test('the rows of the named sections, and no other section', () {
      const String declaration = '''
classes:
  # A path the trunk carries.
  "apps/*/app.yaml": product

trunk-absent:
  # Stands on an install branch.
  "installation/values/manager.yaml": install-branch

outside:
  # Held outside git.
  "apps/*/Chart.lock": product
''';
      expect(declaredAbsentIn(declaration, sections: _absenceSections), <String>{
        'installation/values/manager.yaml',
        'apps/*/Chart.lock',
      });
    });

    test('THE INNOCENT NEIGHBOUR: a section that is not a map answers nothing, never less', () {
      // A row commented out, or a conflict marker standing in the file, must not read as a shorter
      // list — a shorter list of declared-absent paths is a wave of reports about paths nobody
      // moved.
      const String declaration = '''
trunk-absent:
  # "installation/values/manager.yaml": install-branch
''';
      expect(declaredAbsentIn(declaration, sections: _absenceSections), isEmpty);
    });
  });

  group('what it reports', () {
    const Set<String> tracked = <String>{
      'apps/manager/app.yaml',
      'apps/manager/values-common.yaml',
      'argocd/apps/applicationset.yaml',
      'clusters/active/.gitkeep',
    };
    const Set<String> declaredAbsent = <String>{
      'installation/values/manager.yaml',
      'clusters/active/*.yaml',
      'apps/*/Chart.lock',
    };

    test('THE PLANTED DEFECT: a path the repository does not carry, and the file is named', () {
      final List<UnansweredPath> found = auditNamedPaths(
        named: <String, Set<String>>{
          'apps/manager/values-common.yaml': <String>{'installation/apps/manager.yaml'},
        },
        tracked: tracked,
        declaredAbsent: declaredAbsent,
      );
      expect(found, hasLength(1));
      expect(found.single.where, 'apps/manager/values-common.yaml');
      expect(found.single.path, 'installation/apps/manager.yaml');
      expect(found.single.toString(), contains('this repository carries no such path'));
    });

    test('THE PLANTED DEFECT: a tree that became one no longer answers its per-stage name', () {
      expect(
        auditNamedPaths(
          named: <String, Set<String>>{
            'apps/coredns/values-dev.yaml': <String>{'argocd/<stage>/apps/applicationset.yaml'},
          },
          tracked: tracked,
          declaredAbsent: declaredAbsent,
        ),
        hasLength(1),
      );
    });

    test('THE INNOCENT NEIGHBOUR: the path it became is answered', () {
      expect(
        auditNamedPaths(
          named: <String, Set<String>>{
            'apps/coredns/values-dev.yaml': <String>{'argocd/apps/applicationset.yaml'},
          },
          tracked: tracked,
          declaredAbsent: declaredAbsent,
        ),
        isEmpty,
      );
    });

    test('a marker in a named path is answered by any path it could denote', () {
      expect(
        auditNamedPaths(
          named: <String, Set<String>>{
            'branch-classes.yaml': <String>{'apps/<app>/app.yaml', 'apps/*/values-common.yaml'},
          },
          tracked: tracked,
          declaredAbsent: declaredAbsent,
        ),
        isEmpty,
      );
    });

    test('a family with no member standing is still reported', () {
      expect(
        auditNamedPaths(
          named: <String, Set<String>>{
            'branch-classes.yaml': <String>{'apps/<app>/toggle.yaml'},
          },
          tracked: tracked,
          declaredAbsent: declaredAbsent,
        ),
        hasLength(1),
      );
    });

    test('a declared-absent path is answered in BOTH directions', () {
      // The literal row answers the marker (installation/values/<app>.yaml), and the pattern row
      // answers the literal and the marker alike (clusters/active/...). Either side may be the one
      // carrying the wildcard, so both directions are asked.
      expect(
        auditNamedPaths(
          named: <String, Set<String>>{
            'slaves/slave/values-common.yaml': <String>{'installation/values/<app>.yaml'},
            'charts/monitoring/templates/alertmanagerconfigs.yaml': <String>{
              'clusters/active/<fqdn>.yaml',
            },
            'argocd/apps/slaves-appset.yaml': <String>{'clusters/active/*.yaml'},
            '.gitignore': <String>{'apps/*/Chart.lock'},
          },
          tracked: tracked,
          declaredAbsent: declaredAbsent,
        ),
        isEmpty,
      );
    });

    test('THE INNOCENT NEIGHBOUR: a declaration of absence does not admit a neighbouring family', () {
      // clusters/active/*.yaml is declared absent; clusters/active/*.json is a different family and
      // must not ride in on it.
      expect(
        auditNamedPaths(
          named: <String, Set<String>>{
            'argocd/apps/slaves-appset.yaml': <String>{'clusters/active/<fqdn>.json'},
          },
          tracked: tracked,
          declaredAbsent: declaredAbsent,
        ),
        hasLength(1),
      );
    });
  });
}

/// The sections of `branch-classes.yaml` whose rows declare a path this repository does not track.
///
/// `trunk-absent:` is what stands on an install branch or on the books branch; `outside:` is what is
/// held outside git on purpose. Both exist to say exactly what this check needs, so neither list is
/// restated in this suite.
const List<String> _absenceSections = <String>['trunk-absent', 'outside'];

/// Every path each tracked file names, keyed by the file, with this checks package left out.
///
/// The package is left out because the suite you are reading plants paths that do not exist in order
/// to watch the check go red, and a check that reported its own counter-probes could never be green.
Map<String, Set<String>> _namedPathsOf(
  Directory repository,
  Set<String> tracked,
  Set<String> topLevelDirectories,
) {
  final Map<String, Set<String>> named = <String, Set<String>>{};
  for (final String path in tracked) {
    if (path.startsWith('checks/')) {
      continue;
    }
    final File file = File('${repository.path}/$path');
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException {
      continue;
    }
    final Set<String> found = namedPathsIn(text, topLevelDirectories: topLevelDirectories);
    if (found.isNotEmpty) {
      named[path] = found;
    }
  }
  return named;
}

/// What `git ls-files` answers in [repository] — the tree a cluster clones.
Set<String> _tracked(Directory repository) {
  final ProcessResult result = Process.runSync('git', <String>[
    'ls-files',
  ], workingDirectory: repository.path);
  if (result.exitCode != 0) {
    throw StateError('git ls-files failed: ${result.stderr}');
  }
  return <String>{
    for (final String line in (result.stdout as String).split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  };
}
