import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// rendered-registrations — over the real trees, and over planted ones.
///
/// **Why both sides are read and neither may be missing.** A registration an installation program
/// renders is written in the installation's repository; the schema it is read back with is written
/// in the Controller's. Neither repository can see the other, so the suite refuses over a tree it
/// cannot find rather than passing because it found nothing to compare.
void main() {
  group('the trees as they stand', () {
    test('every registration an installation renders parses under the schema that reads it', () {
      final Directory programs = Directory('${installationRoot().path}/$installationPrograms');
      final Map<RenderedRegistration, String> rendered = <RenderedRegistration, String>{};
      for (final File each in programs.listSync().whereType<File>().where(
        (File f) => f.path.endsWith('.yaml'),
      )) {
        for (final RenderedRegistration found in renderedRegistrationsIn(
          program: each.uri.pathSegments.last,
          document: loadYaml(each.readAsStringSync()),
        )) {
          final File template = File('${installationRoot().path}/${found.template}');
          expect(
            template.existsSync(),
            isTrue,
            reason:
                '${found.program} renders ${found.template}, and no such file stands in the '
                'installation — the row would write whatever the step makes of a template that is '
                'not there',
          );
          rendered[found] = template.readAsStringSync();
        }
      }

      final List<DeclaredField> fields = <DeclaredField>[
        for (final String each in <String>['consumer.ts', 'tenant.ts'])
          ...registrationFieldsIn(
            File('${controllerRoot().path}/$controllerShared/$each').readAsStringSync(),
          ),
      ];
      expect(
        fields,
        isNotEmpty,
        reason:
            'no registration schema was read out of the Controller, so every value below would '
            'have been admitted by an empty list of declared fields',
      );

      expect(
        auditRenderedRegistrations(
          rendered: rendered,
          fields: fields,
        ).map((RenderedFinding each) => each.toString()),
        isEmpty,
      );
    });
  });

  group('which rows are the subject', () {
    RenderedRegistration only(String program, String document) {
      final List<RenderedRegistration> found = renderedRegistrationsIn(
        program: program,
        document: loadYaml(document),
      );
      expect(found, hasLength(1));
      return found.single;
    }

    test('a row that writes a template under registrations/ is one', () {
      final RenderedRegistration found = only('deploy-branch.yaml', '''
steps:
  - step: write_file_from_template
    template: ansiwise/templates/platform-build-registration.tpl
    path: /srv/hostyour-cloud/registrations/hostyour-manager/build.yaml
''');
      expect(found.template, 'ansiwise/templates/platform-build-registration.tpl');
      expect(found.path, '/srv/hostyour-cloud/registrations/hostyour-manager/build.yaml');
    });

    test(
      'THE INNOCENT NEIGHBOUR: a template written anywhere else is not this check\'s subject',
      () {
        expect(
          renderedRegistrationsIn(
            program: 'deploy-cluster.yaml',
            document: loadYaml('''
steps:
  - step: write_file_from_template
    template: ansiwise/templates/cluster-map.tpl
    path: /srv/hostyour-cloud/clusters/active/m1.example.com.yaml
'''),
          ),
          isEmpty,
        );
      },
    );

    test('a step of another kind writing there is not one either', () {
      expect(
        renderedRegistrationsIn(
          program: 'deploy-gitops.yaml',
          document: loadYaml('''
steps:
  - step: create_file
    path: /srv/hostyour-cloud/registrations/acme/build.yaml
'''),
        ),
        isEmpty,
      );
    });
  });

  group('what a value is held against', () {
    const RenderedRegistration one = RenderedRegistration(
      program: 'deploy-branch.yaml',
      template: 'ansiwise/templates/platform-build-registration.tpl',
      path: '/srv/hostyour-cloud/registrations/hostyour-manager/build.yaml',
    );
    const List<DeclaredField> declared = <DeclaredField>[
      DeclaredField(schema: 'ConsumerRegistrationSchema', name: 'suspended', type: 'boolean'),
      DeclaredField(schema: 'ConsumerRegistrationSchema', name: 'name', type: 'string'),
    ];

    test('THE DEFECT THIS WAS BUILT AFTER: a boolean field written as a quoted string', () {
      expect(
        auditRenderedRegistrations(
          rendered: <RenderedRegistration, String>{
            one: 'name: hostyour-manager\nsuspended: "false"\n',
          },
          fields: declared,
        ).map((RenderedFinding each) => each.toString()),
        <String>[
          'deploy-branch.yaml renders ansiwise/templates/platform-build-registration.tpl, where '
              '"suspended" is the string "false", and ConsumerRegistrationSchema declares it '
              'z.boolean — the Controller refuses the file, and what an operator is told is '
              'whatever the first reader past the refusal says',
        ],
      );
    });

    test('THE INNOCENT NEIGHBOUR: the same field written unquoted is nothing', () {
      expect(
        auditRenderedRegistrations(
          rendered: <RenderedRegistration, String>{
            one: 'name: hostyour-manager\nsuspended: false\n',
          },
          fields: declared,
        ),
        isEmpty,
      );
    });

    test('a field no schema declares is not this check\'s business', () {
      expect(
        auditRenderedRegistrations(
          rendered: <RenderedRegistration, String>{one: 'builds:\n  - manager\n'},
          fields: declared,
        ),
        isEmpty,
      );
    });

    test('a comment before the first key does not hide the keys under it', () {
      expect(
        auditRenderedRegistrations(
          rendered: <RenderedRegistration, String>{
            one: '# what this is\n#\n# and why\nname: hostyour-manager\nsuspended: "false"\n',
          },
          fields: declared,
        ),
        hasLength(1),
      );
    });
  });
}
