import 'dart:io';

import 'package:hostyour_cloud_gate/hostyour_cloud_gate.dart';
import 'package:test/test.dart';

import 'support/repository_under_check.dart';

/// .gitattributes fixes the bytes of every path of this repository, and this reads it back.
///
/// The audit is [LineEndingAudit]; this file drives it over the repository, where its findings must
/// be empty, and over trees planted for the purpose that carry one instance of every defect it is
/// supposed to find.
///
/// It also asserts the stake directly: the chart templates that ship a shebang inside a YAML block
/// scalar are named here, so that a rewrite which moved them out from under the declaration would
/// be a red test rather than a quiet one.
void main() {
  final Directory scratch = Directory.systemTemp.createTempSync('hostyour-eol-');
  final SourceTree tree = repositoryTree();
  final String? text = tree.textOf(AttributeDeclaration.file);
  final LineEndingAudit audit = LineEndingAudit(
    tree: tree,
    declaration: AttributeDeclaration.parse(text ?? ''),
  );

  tearDownAll(() => scratch.deleteSync(recursive: true));

  group('the repository', () {
    test('carries the declaration at all', () {
      expect(
        text,
        isNotNull,
        reason: 'without it every path here is whatever the developer\'s git config makes of it',
      );
    });

    test('carries no carriage return in anything declared LF', () {
      final List<LineEndingFinding> found = audit.carriageReturnsInLfPaths();
      expect(found, isEmpty, reason: found.join('\n'));
    });

    test('fixes an ending for every text path it tracks', () {
      final List<LineEndingFinding> found = audit.pathsWithNoDeclaredEnding();
      expect(found, isEmpty, reason: found.join('\n'));
    });

    test('carries a tracked path for every rule the declaration writes', () {
      final List<LineEndingFinding> found = audit.rulesThatOwnNothing();
      expect(found, isEmpty, reason: found.join('\n'));
    });
  });

  group('the shebangs this declaration is for', () {
    // What a carriage return would break is not a checked-out script — there are none here. It is
    // the first line of a Tekton script block, which a cluster writes to disk and a pod executes.
    // Each of these is asserted to still hold one AND to still be declared LF, because the check
    // above is only worth its run while both are true.

    const List<String> carryingAScript = <String>[
      'apps/consumer-build/templates/pipeline-release.yaml',
      'apps/gate-runner/templates/task-publish-report.yaml',
      'apps/image-builder/templates/tasks/buildah-build-push.yaml',
      'apps/image-builder/templates/tasks/credential-scan.yaml',
      'apps/image-builder/templates/tasks/git-clone.yaml',
      'apps/service-provisioner/templates/configmap.yaml',
    ];

    for (final String path in carryingAScript) {
      test('$path ships a shebang and is declared LF', () {
        expect(
          tree.textOf(path),
          contains('#!'),
          reason: 'the script this file delivers to a pod is why the ending of it is fixed',
        );
        expect(
          AttributeDeclaration.parse(text ?? '').endingOf(path),
          DeclaredEnding.lf,
          reason: 'a \\r here arrives as "bad interpreter: /usr/bin/env bash^M" inside a pod',
        );
      });
    }
  });

  group('the declaration is read the way git reads it', () {
    test('the last matching rule wins, not the first', () {
      final AttributeDeclaration declaration = AttributeDeclaration.parse(
        '* text=auto eol=lf\n*.tgz binary\n',
      );
      expect(declaration.endingOf('apps/probe/charts/x.tgz'), DeclaredEnding.binary);
      expect(declaration.endingOf('apps/probe/values.yaml'), DeclaredEnding.lf);
    });

    test('a pattern with no slash is matched against the file name', () {
      final AttributeDeclaration declaration = AttributeDeclaration.parse('*.yaml text eol=lf\n');
      expect(declaration.endingOf('apps/probe/templates/deep.yaml'), DeclaredEnding.lf);
    });

    test('a pattern with a slash is matched against the whole path, and stops at a separator', () {
      final AttributeDeclaration declaration = AttributeDeclaration.parse(
        'cluster/* text eol=lf\n',
      );
      expect(declaration.endingOf('cluster/profile.yaml'), DeclaredEnding.lf);
      expect(declaration.endingOf('cluster/apps/registry.yaml'), DeclaredEnding.undeclared);
    });

    test('text with no eol fixes nothing, because the machine then decides', () {
      final AttributeDeclaration declaration = AttributeDeclaration.parse('* text\n');
      expect(declaration.endingOf('anything.yaml'), DeclaredEnding.undeclared);
    });

    test('a comment and a bare pattern state nothing', () {
      expect(AttributeDeclaration.parse('# * text eol=lf\n*.yaml\n').rules, isEmpty);
    });
  });

  group('counter-probe', () {
    // The same audit over trees carrying one instance of every defect, each beside a correct
    // neighbour — so a check that reported everything is caught as surely as one that reports
    // nothing.

    late List<LineEndingFinding> found;

    setUpAll(() {
      final SourceTree probe = SourceTree.planted(
        Directory('${scratch.path}${Platform.pathSeparator}probe')..createSync(recursive: true),
        <String, String>{
          'apps/probe/templates/task.yaml': 'script: |\r\n  #!/usr/bin/env sh\r\n  echo hi\r\n',
          'apps/probe/templates/clean.yaml': 'script: |\n  #!/usr/bin/env sh\n  echo hi\n',
          'apps/probe/notes.txt': 'nothing declares this one\n',
        },
      );
      found = LineEndingAudit(
        tree: probe,
        declaration: AttributeDeclaration.parse(_declarationCarryingEveryDefect),
      ).findings();
    });

    test('a path declared LF carrying a carriage return is reported', () {
      expect(
        found,
        contains(
          predicate<LineEndingFinding>(
            (LineEndingFinding f) =>
                f is CarriageReturnInAnLfPath &&
                f.path == 'apps/probe/templates/task.yaml' &&
                f.line == 1,
          ),
        ),
        reason: 'the byte scan cannot go red',
      );
    });

    test('the file beside it that carries none is not reported', () {
      expect(
        found.whereType<CarriageReturnInAnLfPath>().map((CarriageReturnInAnLfPath f) => f.path),
        isNot(contains('apps/probe/templates/clean.yaml')),
        reason: 'the byte scan reports whatever it is given',
      );
    });

    test('a text path no rule owns is reported', () {
      expect(
        found,
        contains(
          predicate<LineEndingFinding>(
            (LineEndingFinding f) =>
                f is PathWithNoDeclaredEnding && f.path == 'apps/probe/notes.txt',
          ),
        ),
      );
    });

    test('a rule that owns nothing is reported', () {
      expect(
        found,
        contains(
          predicate<LineEndingFinding>(
            (LineEndingFinding f) => f is AttributeRuleOwnsNothing && f.rule.startsWith('*.sh '),
          ),
        ),
      );
    });

    test('a declaration none of whose rules owns anything is reported as measuring nothing', () {
      final Directory bare = Directory('${scratch.path}${Platform.pathSeparator}bare')
        ..createSync(recursive: true);
      final LineEndingAudit audit = LineEndingAudit(
        tree: SourceTree.planted(bare, <String, String>{'kept.yaml': 'a: b\n'}),
        declaration: AttributeDeclaration.parse('*.sh text eol=lf\n'),
      );
      expect(audit.rulesThatOwnNothing(), <Matcher>[isA<NothingIsDeclared>()]);
    });
  });
}

/// A declaration carrying one instance of every defect the audit is supposed to find.
///
/// `*.yaml` is the correct neighbour: it owns two of the three planted paths, so the dead-rule half
/// reports `*.sh` alone rather than everything it was handed.
const String _declarationCarryingEveryDefect = '''
*.yaml text eol=lf
*.sh text eol=lf
''';
