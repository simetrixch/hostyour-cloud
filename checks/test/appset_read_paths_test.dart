import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';

/// appset-read-paths — over the real trees, and over planted ones.
///
/// **What this is guarding.** Every ApplicationSet of this repository loads
/// `installation/profile.yaml` last in its values chain, and the trunk carries that file empty
/// because the trunk knows no installation. Take the writer away and the entry still resolves — the
/// empty trunk copy answers it — so every Application renders without the values it names, syncs and
/// reports Healthy. That state was measured green through the whole gate before this check existed.
///
/// **Why nothing here writes a path or a class.** What a path IS stands in `branch-classes.yaml`;
/// what an ApplicationSet reads stands in the manifests; what a program writes stands in the
/// programs. A list of any of them here would be a second spelling of a file this suite is watching
/// for drift in, and the drift could then happen inside the guard.
void main() {
  final Directory repository = Directory.current.parent;
  final Set<String> tracked = _git(repository, <String>['ls-files']).toSet();

  group('the trees as they stand', () {
    test('every install path an ApplicationSet of this repository reads has a writer', () {
      final Directory installation = installationRoot();
      final Set<String> directories = _topLevelDirectoriesIn(tracked);
      expect(
        directories,
        isNotEmpty,
        reason: 'this repository tracks no directory — git ls-files was not read',
      );

      final List<PathClass> rules = pathClassesIn(
        File('${repository.path}/$branchClassesPath').readAsStringSync(),
      );
      expect(
        rules,
        isNotEmpty,
        reason:
            '$branchClassesPath declares no path class — the declaration this check reads what a '
            'path IS out of was not read, and a comparison against nothing passes',
      );

      final Map<String, Set<String>> read = <String, Set<String>>{
        for (final MapEntry<String, String> manifest in _appsetMaterial(
          repository,
          tracked,
        ).entries)
          manifest.key: appsetReadPathsIn(manifest.value),
      };
      // A comparison against nothing reads like a pass, which is the failure this whole suite
      // exists to refuse. Every side is asserted present before any of them is judged.
      expect(
        read.values.expand((Set<String> each) => each),
        isNotEmpty,
        reason: 'no ApplicationSet of this repository reads a path — the manifests were not read',
      );
      expect(
        <String>{
          for (final Set<String> paths in read.values)
            for (final String path in paths)
              if (classOf(path, rules: rules) == installClass) path,
        },
        isNotEmpty,
        reason:
            'no path any ApplicationSet reads carries the class "$installClass" — either the '
            'manifests or $branchClassesPath were not read, and this check then holds nothing',
      );

      final Map<String, String> programs = _programsIn(installation);
      expect(
        programs,
        isNotEmpty,
        reason: 'no program stands under $installationPrograms — the tree was not read',
      );
      final Set<String> written = <String>{
        for (final String program in programs.values)
          ...writtenPathsIn(
            program,
            roots: platformCheckoutRootsIn(program, directories: directories),
          ),
      };
      expect(
        written,
        isNotEmpty,
        reason:
            'no program writes a file into a checkout of this repository — either the programs or '
            'the checkout roots were not read',
      );

      expect(
        auditReadPaths(
          read: read,
          written: written,
          rules: rules,
        ).map((UnwrittenReadPath each) => each.toString()),
        isEmpty,
      );
    });

    test('WHAT IT DOES NOT REACH: a path an ApplicationSet reads that no rule owns', () {
      // A read path with no class is left alone, and there is one today. Naming it here is what
      // keeps a green run from being read as a statement about it.
      final List<PathClass> rules = pathClassesIn(
        File('${repository.path}/$branchClassesPath').readAsStringSync(),
      );
      final Set<String> unowned = <String>{
        for (final String manifest in _appsetMaterial(repository, tracked).values)
          for (final String path in appsetReadPathsIn(manifest))
            if (classOf(path, rules: rules) == null) path,
      };

      expect(
        unowned,
        isNotEmpty,
        reason:
            'every path an ApplicationSet reads now carries a class — a read this check passes '
            'over silently has moved into its reach without the note moving too',
      );
    });
  });

  group('what it reads out of the declaration', () {
    const String declaration = '''
classes:
  "apps/*/values-common.yaml": product
  "installation/profile.yaml": install
  "installation/values/manager.yaml": install
  "clusters/active/*.yaml": books
''';

    test('the rules keep the order the file declares them in, because first match owns', () {
      expect(pathClassesIn(declaration).map((PathClass each) => each.pattern), <String>[
        'apps/*/values-common.yaml',
        'installation/profile.yaml',
        'installation/values/manager.yaml',
        'clusters/active/*.yaml',
      ]);
    });

    test('a path gets the class of the rule that owns it', () {
      final List<PathClass> rules = pathClassesIn(declaration);
      expect(classOf('installation/profile.yaml', rules: rules), 'install');
      expect(classOf('clusters/active/*.yaml', rules: rules), 'books');
    });

    test("a rule's star crosses a slash, which is the sense the declaration states", () {
      expect(patternOwns('charts/*', 'charts/common/templates/x.yaml'), isTrue);
    });

    test('a slot in the READ path stands for one segment, never for a directory', () {
      expect(
        patternOwns('installation/values/manager.yaml', 'installation/values/{{ .name }}.yaml'),
        isTrue,
      );
      expect(
        patternOwns('installation/values/manager.yaml', 'installation/{{ .name }}.yaml'),
        isFalse,
      );
    });

    test('THE PLANTED RENAME: one letter apart is owned by neither', () {
      final List<PathClass> rules = pathClassesIn(declaration);
      expect(classOf('cluster/profile.yaml', rules: rules), isNull);
    });

    test('a declaration with no classes section is read as empty, never as an error', () {
      expect(pathClassesIn('stamped:\n  "a.yaml": b\n'), isEmpty);
      expect(pathClassesIn('classes:\n'), isEmpty);
    });
  });

  group('what it refuses', () {
    final List<PathClass> rules = pathClassesIn('''
classes:
  "installation/profile.yaml": install
  "installation/values/manager.yaml": install
  "platform/values-common.yaml": product
  "clusters/active/*.yaml": books
''');

    test('THE PLANTED DEFECT: every reader moved and the writer never followed', () {
      final List<UnwrittenReadPath> found = auditReadPaths(
        read: <String, Set<String>>{
          'argocd/apps/applicationset.yaml': <String>{
            'installation/profile.yaml',
            'platform/values-common.yaml',
          },
        },
        written: <String>{'cluster/profile.yaml'},
        rules: rules,
      );

      expect(found, hasLength(1));
      expect(found.single.where, 'argocd/apps/applicationset.yaml');
      expect(found.single.path, 'installation/profile.yaml');
      expect(found.single.toString(), contains('no program of this installation writes it'));
    });

    test('THE INNOCENT NEIGHBOURS: a product path and a books path need no writer', () {
      expect(
        auditReadPaths(
          read: <String, Set<String>>{
            'argocd/apps/slaves-appset.yaml': <String>{
              'platform/values-common.yaml',
              'clusters/active/*.yaml',
            },
          },
          written: const <String>{},
          rules: rules,
        ),
        isEmpty,
      );
    });

    test('a write through a slot answers a read through a render-time action', () {
      expect(
        auditReadPaths(
          read: <String, Set<String>>{
            'argocd/apps/applicationset.yaml': <String>{'installation/values/{{ .name }}.yaml'},
          },
          written: <String>{'installation/values/postfix.yaml'},
          rules: rules,
        ),
        isEmpty,
      );
    });

    test('every manifest that reads an unwritten path is named, never only the first', () {
      final List<UnwrittenReadPath> found = auditReadPaths(
        read: <String, Set<String>>{
          'a.yaml': <String>{'installation/profile.yaml'},
          'b.yaml': <String>{'installation/profile.yaml'},
        },
        written: const <String>{},
        rules: rules,
      );
      expect(found.map((UnwrittenReadPath each) => each.where), <String>['a.yaml', 'b.yaml']);
    });

    test('an empty declaration holds nothing, which is why the suite asserts it is not empty', () {
      expect(
        auditReadPaths(
          read: <String, Set<String>>{
            'a.yaml': <String>{'installation/profile.yaml'},
          },
          written: const <String>{},
          rules: const <PathClass>[],
        ),
        isEmpty,
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

/// Every tracked manifest of this repository that declares an ApplicationSet.
///
/// Found by the kind the file declares rather than by the directory it stands in, for the reason the
/// sibling suite states: this repository keeps ApplicationSets in two places, and a reader bound to
/// one of them would watch half.
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
