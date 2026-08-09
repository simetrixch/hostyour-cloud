import 'dart:io';

import 'package:hostyour_cloud_gate/hostyour_cloud_gate.dart';
import 'package:test/test.dart';

import 'support/repository_under_check.dart';

/// Every Dart directive of this tree spells the path it names byte for byte.
///
/// This tree is edited on Windows and cloned onto Linux, and an import spelled `Tree/` for a
/// directory tracked as `tree/` is the one defect that is invisible on the first machine and fatal
/// on the second. The audit is [DirectiveCaseAudit]; this file drives it over the repository, where
/// its findings must be empty, and over trees planted for the purpose.
///
/// WHY A PLANTED TREE AND NOT A STRING. The audit compares against the LISTING, so a counter-probe
/// has to give it a listing — a file really written under one spelling and a directive really
/// written under another. Asserting against a description of that would be asserting against this
/// file's own idea of the defect rather than against the defect.
void main() {
  group('the repository', () {
    final DirectiveCaseAudit audit = DirectiveCaseAudit(repositoryTree());

    test('has directives of its own to judge', () {
      expect(
        audit.judged,
        isNotEmpty,
        reason: 'no directive here names a file of this tree, so this check measured nothing',
      );
    });

    test('spells every one of them the way the tracked path is spelled', () {
      final List<DirectiveCaseFinding> found = audit.findings();
      expect(found, isEmpty, reason: found.join('\n'));
    });
  });

  group('counter-probe', () {
    late Directory probeRoot;

    setUp(() {
      probeRoot = Directory.systemTemp.createTempSync('hostyour-directive-case-');
    });
    tearDown(() => probeRoot.deleteSync(recursive: true));

    DirectiveCaseAudit auditOf(Map<String, String> files) =>
        DirectiveCaseAudit(SourceTree.planted(probeRoot, files));

    test('a file name whose case differs from the tracked one is reported', () {
      final List<DirectiveCaseFinding> found = auditOf(<String, String>{
        'lib/render/value_stack.dart': 'const int x = 1;',
        'lib/wrong.dart': "import 'render/Value_stack.dart';",
      }).findings();
      expect(found, hasLength(1), reason: 'this scan cannot go red on the defect it exists for');
      expect(
        found.single.tracked,
        'lib/render/value_stack.dart',
        reason: 'a finding that does not name the tracked spelling leaves the fix to a guess',
      );
    });

    test('a directive that matches byte for byte is not reported', () {
      expect(
        auditOf(<String, String>{
          'lib/render/value_stack.dart': 'const int x = 1;',
          'lib/right.dart': "import 'render/value_stack.dart';",
        }).findings(),
        isEmpty,
        reason: 'this scan refuses correct code',
      );
    });

    test('a directory segment with the wrong case is reported', () {
      expect(
        auditOf(<String, String>{
          'lib/render/value_stack.dart': 'const int x = 1;',
          'lib/wrong.dart': "import 'Render/value_stack.dart';",
        }).findings(),
        hasLength(1),
        reason:
            'the whole resolved path is compared and not the file name alone; a directory opened '
            'under the wrong case fails on Linux exactly like a file',
      );
    });

    test('a relative path that climbs is resolved before it is compared', () {
      expect(
        auditOf(<String, String>{
          'lib/src/tree/source_tree.dart': 'const int x = 1;',
          'lib/src/pins/wrong.dart': "import '../tree/Source_tree.dart';",
        }).findings(),
        hasLength(1),
      );
    });

    test('a package: directive of a package this tree declares is judged like a relative one', () {
      final List<DirectiveCaseFinding> found = auditOf(<String, String>{
        'tools/pubspec.yaml': 'name: planted_gate\n',
        'tools/lib/src/tree/source_tree.dart': 'const int x = 1;',
        'tools/test/wrong_test.dart': "import 'package:planted_gate/src/tree/Source_tree.dart';",
        'tools/test/right_test.dart': "import 'package:planted_gate/src/tree/source_tree.dart';",
      }).findings();
      expect(found, hasLength(1));
      expect(found.single.directive.file, 'tools/test/wrong_test.dart');
    });

    test('an export and a part are judged like an import', () {
      expect(
        auditOf(<String, String>{
          'lib/render/value_stack.dart': 'const int x = 1;',
          'lib/exports.dart': "export 'render/Value_stack.dart';",
          'lib/parent.dart': "part 'render/Value_stack.dart';",
        }).findings(),
        hasLength(2),
        reason: 'an export and a part resolve a file exactly as an import does',
      );
    });

    test('a part of naming its parent with the wrong case is reported', () {
      expect(
        auditOf(<String, String>{
          'lib/parent.dart': "part 'child.dart';",
          'lib/child.dart': "part of 'Parent.dart';",
        }).findings(),
        hasLength(1),
        reason: 'the child names its parent on its own, so the parent directive does not cover it',
      );
    });

    test('a directive naming a path tracked under no spelling is not a finding here', () {
      expect(
        auditOf(<String, String>{'lib/broken.dart': "import 'render/not_there.dart';"}).findings(),
        isEmpty,
        reason: 'that import is broken on every platform, and the analyzer reports it',
      );
    });

    test('dart: and a package this tree does not declare are not judged', () {
      final DirectiveCaseAudit audit = auditOf(<String, String>{
        'lib/uses_others.dart': "import 'dart:io';\nimport 'package:Yaml/yaml.dart';",
      });
      expect(
        audit.judged,
        isEmpty,
        reason:
            'dart: names no file, and a package this tree does not declare resolves through the '
            "pub cache, whose spelling is pub's",
      );
      expect(audit.findings(), isEmpty);
    });
  });
}
