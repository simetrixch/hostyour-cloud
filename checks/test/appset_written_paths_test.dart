import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';

/// appset-written-paths — over the real trees, and over planted ones.
///
/// **What this is guarding.** The files an installation's own answers stand in are written by a
/// deploy program in one repository and read by an ApplicationSet in this one. Rename such a file
/// here and leave the program writing the old name, and both files stand on the branch: the trunk's
/// copy at the new name, which knows no installation, and the run's rendered copy at the old name,
/// which nothing loads. The cluster then renders every Application without the values it depends on
/// and reports nothing at all — the run is green, the sync is green, and this suite was measured
/// green through exactly that state before it existed.
///
/// **Why nothing here writes a path or a checkout root.** A list of them in this suite would be a
/// third spelling of what two repositories already say, and the drift being watched for could then
/// happen inside the guard. Which checkouts are of this repository is read out of the trees the
/// programs stamp; what is written and what is read are read out of the programs and the manifests.
void main() {
  final Directory repository = Directory.current.parent;
  final Set<String> tracked = _git(repository, <String>['ls-files']).toSet();

  group('the trees as they stand', () {
    test('every path the deploy programs write into a checkout of this repository is read', () {
      final Directory installation = installationRoot();
      final Set<String> directories = _topLevelDirectoriesIn(tracked);
      expect(
        directories,
        isNotEmpty,
        reason: 'this repository tracks no directory — git ls-files was not read',
      );

      final Map<String, String> programs = _programsIn(installation);
      expect(
        programs,
        isNotEmpty,
        reason: 'no program stands under $installationPrograms — the tree was not read',
      );

      final Map<String, Set<String>> written = <String, Set<String>>{};
      for (final MapEntry<String, String> program in programs.entries) {
        final Set<String> roots = platformCheckoutRootsIn(program.value, directories: directories);
        if (roots.isEmpty) {
          continue;
        }
        final Set<String> paths = writtenPathsIn(program.value, roots: roots);
        if (paths.isNotEmpty) {
          written[program.key] = paths;
        }
      }
      // A comparison against nothing reads like a pass, which is the failure this whole suite
      // exists to refuse. Both sides are asserted present before either is judged.
      expect(
        written,
        isNotEmpty,
        reason:
            'no program writes a file into a checkout of this repository — either the programs or '
            'the checkout roots were not read',
      );

      final Set<String> read = <String>{
        for (final String manifest in _appsetMaterial(repository, tracked).values)
          ...appsetReadPathsIn(manifest),
      };
      expect(
        read,
        isNotEmpty,
        reason: 'no ApplicationSet of this repository reads a path — the manifests were not read',
      );

      expect(
        auditWrittenPaths(
          written: written,
          read: read,
        ).map((UnreadWrittenPath each) => each.toString()),
        isEmpty,
      );
    });

    test('WHAT IT DOES NOT REACH: the checkouts the programs work in outside this repository', () {
      // A program writes into the machine and into the tenant catalog as well, and neither is this
      // repository's to answer for. Naming them here is what keeps a green run from being read as a
      // statement about them.
      final Directory installation = installationRoot();
      final Set<String> directories = _topLevelDirectoriesIn(tracked);
      final Map<String, String> programs = _programsIn(installation);

      final Set<String> roots = <String>{
        for (final String program in programs.values)
          ...platformCheckoutRootsIn(program, directories: directories),
      };
      final Set<String> written = <String>{
        for (final String program in programs.values)
          for (final String path in _absoluteWritePathsIn(program))
            if (!roots.any((String root) => path.startsWith('$root/'))) path,
      };

      expect(
        written,
        isNotEmpty,
        reason:
            'every path the programs write now stands in a checkout of this repository — a write '
            'this check passes over silently has moved into its reach without the note moving too',
      );
    });
  });

  group('what it reads out of a program', () {
    const String stamped = '''
steps:
  - step: stamp_placeholder_in_tracked_files
    repository: /srv/hostyour-cloud
    tree: argocd
  - step: stamp_placeholder_in_tracked_files
    repository: /srv/ansiwise-catalog
    tree: charts
  - step: write_file_from_template
    template: t.tpl
    path: /srv/hostyour-cloud/installation/profile.yaml
  - step: write_file_from_template
    template: t.tpl
    path: /etc/netplan/60-public-src-routing.yaml
''';

    test('a checkout is the root a program stamps a tree THIS repository tracks in', () {
      expect(platformCheckoutRootsIn(stamped, directories: <String>{'argocd', 'apps'}), <String>{
        '/srv/hostyour-cloud',
      });
    });

    test('THE INNOCENT NEIGHBOUR: a root stamped in a tree of another repository is not one', () {
      // `charts` is a directory the tenant catalog has and this repository does not, so the
      // catalog's checkout is not mistaken for one of ours.
      expect(
        platformCheckoutRootsIn(stamped, directories: <String>{'argocd'}),
        isNot(contains('/srv/ansiwise-catalog')),
      );
    });

    test('a write is made relative to the root it stands in', () {
      expect(writtenPathsIn(stamped, roots: <String>{'/srv/hostyour-cloud'}), <String>{
        'installation/profile.yaml',
      });
    });

    test('THE INNOCENT NEIGHBOUR: a write outside every root is passed over, not reported', () {
      expect(
        writtenPathsIn(stamped, roots: <String>{'/srv/hostyour-cloud'}),
        isNot(contains('/etc/netplan/60-public-src-routing.yaml')),
      );
    });

    test('a root named with a trailing slash is the same root', () {
      const String slashed = '''
steps:
  - step: stamp_placeholder_in_tracked_files
    repository: /srv/hostyour-cloud/
    tree: argocd
''';
      expect(platformCheckoutRootsIn(slashed, directories: <String>{'argocd'}), <String>{
        '/srv/hostyour-cloud',
      });
    });

    test('a program with no steps at all is read as writing nothing, never as an error', () {
      expect(platformCheckoutRootsIn('name: x\n', directories: <String>{'argocd'}), isEmpty);
      expect(writtenPathsIn('name: x\n', roots: <String>{'/srv/hostyour-cloud'}), isEmpty);
    });
  });

  group('what it reads out of a manifest', () {
    test('a valueFiles entry under a ref is read, and its ref is dropped', () {
      const String appset = '''
spec:
  template:
    spec:
      sources:
        - repoURL: https://example.invalid/x.git
          helm:
            valueFiles:
              - \$values/installation/profile.yaml
              - values-__STAGE__.yaml
''';
      expect(appsetReadPathsIn(appset), contains('installation/profile.yaml'));
    });

    test('a chart-relative entry is not a path of this repository and is left out', () {
      const String appset = '''
spec:
  template:
    spec:
      sources:
        - helm:
            valueFiles:
              - values-common.yaml
''';
      expect(appsetReadPathsIn(appset), isEmpty);
    });

    test('a generator glob is read as well, which is how a books path is answered', () {
      const String appset = '''
spec:
  generators:
    - git:
        files:
          - path: "clusters/active/*.yaml"
''';
      expect(appsetReadPathsIn(appset), <String>{'clusters/active/*.yaml'});
    });

    test('a nested git generator is found — a matrix puts it one level further down', () {
      const String appset = '''
spec:
  generators:
    - matrix:
        generators:
          - git:
              files:
                - path: "registrations/*/build.yaml"
''';
      expect(appsetReadPathsIn(appset), <String>{'registrations/*/build.yaml'});
    });

    test('two documents in one file are both read', () {
      const String appset = '''
spec:
  generators:
    - git:
        files:
          - path: "a/*.yaml"
---
spec:
  generators:
    - git:
        files:
          - path: "b/*.yaml"
''';
      expect(appsetReadPathsIn(appset), <String>{'a/*.yaml', 'b/*.yaml'});
    });
  });

  group('what answers what', () {
    test("a generator's glob answers a path written through a slot", () {
      expect(readAnswersWritten('clusters/active/*.yaml', 'clusters/active/<fqdn>.yaml'), isTrue);
    });

    test('a path composed at render time answers the one file written under it', () {
      expect(
        readAnswersWritten(
          'installation/values/{{ .name }}.yaml',
          'installation/values/postfix.yaml',
        ),
        isTrue,
      );
    });

    test('a stamp marker in the read path stands for one segment, not for a directory', () {
      expect(
        readAnswersWritten('platform/values-__STAGE__.yaml', 'platform/values-dev.yaml'),
        isTrue,
      );
      expect(
        readAnswersWritten('registrations/*/build.yaml', 'registrations/a/b/build.yaml'),
        isFalse,
      );
    });

    test('THE PLANTED RENAME: one letter apart is not answered', () {
      expect(readAnswersWritten('installation/profile.yaml', 'cluster/profile.yaml'), isFalse);
      expect(readAnswersWritten('clusters/active/*.yaml', 'cluster/active/x.yaml'), isFalse);
    });

    test('a shape with no wildcard cannot answer a path that has one', () {
      expect(
        readAnswersWritten('installation/profile.yaml', 'installation/<x>profile.yaml'),
        isFalse,
      );
    });
  });

  group('what it refuses', () {
    test('THE PLANTED DEFECT: the writer left behind while every reader moved', () {
      final List<UnreadWrittenPath> found = auditWrittenPaths(
        written: <String, Set<String>>{
          'ansiwise/programs/deploy-branch.yaml': <String>{
            'cluster/profile.yaml',
            'clusters/active/<fqdn>.yaml',
          },
        },
        read: <String>{'installation/profile.yaml', 'clusters/active/*.yaml'},
      );

      expect(found, hasLength(1));
      expect(found.single.where, 'ansiwise/programs/deploy-branch.yaml');
      expect(found.single.path, 'cluster/profile.yaml');
      expect(
        found.single.toString(),
        contains('no ApplicationSet of this repository loads it as a values file'),
      );
    });

    test('THE INNOCENT NEIGHBOURS: every written path some reader answers passes', () {
      expect(
        auditWrittenPaths(
          written: <String, Set<String>>{
            'p.yaml': <String>{
              'installation/profile.yaml',
              'installation/values/postfix.yaml',
              'clusters/active/<fqdn>.yaml',
              'registrations/hostyour-manager/build.yaml',
            },
          },
          read: <String>{
            'installation/profile.yaml',
            'installation/values/{{ .name }}.yaml',
            'clusters/active/*.yaml',
            'registrations/*/build.yaml',
          },
        ),
        isEmpty,
      );
    });

    test('every program that writes an unread path is named, never only the first', () {
      final List<UnreadWrittenPath> found = auditWrittenPaths(
        written: <String, Set<String>>{
          'a.yaml': <String>{'gone/one.yaml'},
          'b.yaml': <String>{'gone/two.yaml'},
        },
        read: <String>{'installation/profile.yaml'},
      );
      expect(found.map((UnreadWrittenPath each) => each.where), <String>['a.yaml', 'b.yaml']);
    });

    test('nothing read means every written path is reported, which is what a refusal must do', () {
      expect(
        auditWrittenPaths(
          written: <String, Set<String>>{
            'p.yaml': <String>{'installation/profile.yaml'},
          },
          read: const <String>{},
        ),
        hasLength(1),
      );
    });
  });
}

/// Every top-level directory the tracked tree carries.
Set<String> _topLevelDirectoriesIn(Set<String> tracked) => <String>{
  for (final String path in tracked)
    if (path.contains('/')) path.substring(0, path.indexOf('/')),
};

/// Every program of [installation], by the path the installation tree names it at.
Map<String, String> _programsIn(Directory installation) {
  final Directory programs = Directory('${installation.path}/$installationPrograms');
  return <String, String>{
    for (final FileSystemEntity each in programs.listSync())
      if (each is File && each.path.endsWith('.yaml'))
        '$installationPrograms/${each.uri.pathSegments.last}': each.readAsStringSync(),
  };
}

/// Every absolute path [program] writes, whichever checkout or machine directory it stands in.
Set<String> _absoluteWritePathsIn(String program) =>
    writtenPathsIn(program, roots: <String>{''}).map((String path) => '/$path').toSet();

/// Every tracked manifest of this repository that declares an ApplicationSet.
///
/// Found by the kind the file declares rather than by the directory it stands in: this repository
/// keeps ApplicationSets in two places — the reconciler's own under `argocd/apps/`, and the one a
/// consumer's build chart ships as a file — and a reader bound to one of them would watch half.
Map<String, String> _appsetMaterial(Directory repository, Set<String> tracked) {
  final Map<String, String> found = <String, String>{};
  for (final String path in tracked) {
    if (!path.endsWith('.yaml') && !path.endsWith('.yml')) {
      continue;
    }
    final String content = File('${repository.path}/$path').readAsStringSync();
    if (RegExp(r'^kind:\s*ApplicationSet\s*$', multiLine: true).hasMatch(content)) {
      found[path] = content;
    }
  }
  return found;
}

List<String> _git(Directory repository, List<String> arguments) {
  final ProcessResult result = Process.runSync(
    'git',
    arguments,
    workingDirectory: repository.path,
    stdoutEncoding: const SystemEncoding(),
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
