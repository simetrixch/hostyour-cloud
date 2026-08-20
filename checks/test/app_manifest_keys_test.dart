import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// app-manifest-keys — over the real tree, and over planted ones.
///
/// **Why the requirement is read out of the template.** A list written here would be a second truth:
/// the day somebody adds a bare `{{ .region }}` to the generator, a list still saying six keys goes
/// on passing over the manifest that now ends every reconcile. So the template is the source, and
/// what the probes below plant is a template as much as a manifest.
void main() {
  final Directory repository = Directory.current.parent;

  group('the tree as it stands', () {
    test('every app.yaml carries every key the generator reads bare', () {
      final File generator = File('${repository.path}/argocd/apps/applicationset.yaml');
      expect(generator.existsSync(), isTrue, reason: 'the generator is what makes these required');

      final Map<String, Map<String, Object?>> manifests = <String, Map<String, Object?>>{};
      for (final FileSystemEntity each in Directory('${repository.path}/apps').listSync()) {
        final File manifest = File('${each.path}/app.yaml');
        if (!manifest.existsSync()) {
          continue;
        }
        final Object? parsed = loadYaml(manifest.readAsStringSync());
        manifests['apps/${each.uri.pathSegments[each.uri.pathSegments.length - 2]}/app.yaml'] =
            parsed is Map ? Map<String, Object?>.from(parsed) : <String, Object?>{};
      }
      expect(manifests, isNotEmpty, reason: 'a check over nothing reads like a pass');

      expect(
        auditAppManifestKeys(
          template: generator.readAsStringSync(),
          manifests: manifests,
        ).map((MissingKey each) => each.toString()),
        isEmpty,
      );
    });

    test('every directory under apps/ carries an app.yaml, with no exception list', () {
      final Set<String> tracked =
          Process.runSync('git', <String>['ls-files'], workingDirectory: repository.path).stdout
              .toString()
              .split('\n')
              .map((String each) => each.trim())
              .where((String each) => each.isNotEmpty)
              .toSet();
      expect(tracked, isNotEmpty, reason: 'a check over nothing reads like a pass');

      expect(appDirectoriesWithoutManifest(tracked), isEmpty);
    });
  });

  group('what makes a key required', () {
    test('a bare read does', () {
      expect(requiredKeysIn('name: {{ .name }}\nproject: {{ .project }}'), <String>{
        'name',
        'project',
      });
    });

    test('THE INNOCENT NEIGHBOUR: a read through dig does not', () {
      // dig answers a default where the key is absent, so the template has already said what it does
      // without it. Reporting it would demand a key the generator never needs.
      expect(requiredKeysIn('{{- with dig "serverSideApply" "" . }}x{{- end }}'), isEmpty);
    });

    test('a key read both ways is not required, because one of the reads survives its absence', () {
      expect(requiredKeysIn('{{ .name }}\n{{- with dig "name" "" . }}x{{- end }}'), isEmpty);
    });
  });

  group('what it reports', () {
    const String template = 'name: {{ .name }}\nwave: {{ .syncWave }}';

    test('the planted defect: a manifest missing one key the template reads', () {
      final List<MissingKey> found = auditAppManifestKeys(
        template: template,
        manifests: <String, Map<String, Object?>>{
          'apps/one/app.yaml': <String, Object?>{'name': 'one'},
        },
      );

      expect(found, hasLength(1));
      expect(found.single.manifest, 'apps/one/app.yaml');
      expect(found.single.key, 'syncWave');
      expect(found.single.toString(), contains('ends the whole reconcile'));
    });

    test('the planted innocent: a manifest carrying all of them', () {
      expect(
        auditAppManifestKeys(
          template: template,
          manifests: <String, Map<String, Object?>>{
            'apps/one/app.yaml': <String, Object?>{'name': 'one', 'syncWave': '20'},
          },
        ),
        isEmpty,
      );
    });

    test('a key the template gains makes every manifest that lacks it report', () {
      // The reason the requirement is read rather than listed: this is what a list would miss.
      final List<MissingKey> found = auditAppManifestKeys(
        template: '$template\nregion: {{ .region }}',
        manifests: <String, Map<String, Object?>>{
          'apps/one/app.yaml': <String, Object?>{'name': 'one', 'syncWave': '20'},
          'apps/two/app.yaml': <String, Object?>{'name': 'two', 'syncWave': '30'},
        },
      );

      expect(found.map((MissingKey each) => each.manifest), <String>[
        'apps/one/app.yaml',
        'apps/two/app.yaml',
      ]);
    });
  });

  group('what makes a directory an application', () {
    test('the planted defect: a directory under apps/ with no app.yaml', () {
      expect(
        appDirectoriesWithoutManifest(<String>{
          'apps/one/app.yaml',
          'apps/one/Chart.yaml',
          'apps/two/Chart.yaml',
        }),
        <String>['apps/two'],
      );
    });

    test('THE INNOCENT NEIGHBOUR: the same chart one directory out is not judged at all', () {
      // What the defect above is fixed BY: the chart moves out of apps/ rather than being carried
      // as a name the check has to know about.
      expect(
        appDirectoriesWithoutManifest(<String>{
          'apps/one/app.yaml',
          'apps/one/Chart.yaml',
          'units/two/Chart.yaml',
          'slaves/three/Chart.yaml',
        }),
        isEmpty,
      );
    });

    test('a file directly under apps/ names no directory', () {
      expect(appDirectoriesWithoutManifest(<String>{'apps/README.md'}), isEmpty);
    });
  });
}
