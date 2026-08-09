import 'dart:io';

import 'package:hostyour_cloud_gate/hostyour_cloud_gate.dart';
import 'package:test/test.dart';

import 'support/repository_under_check.dart';

/// branch-classes.yaml says what every path of this repository IS, and this is what reads it back.
///
/// The audit is [BranchClassAudit]; this file drives it over the repository, where its findings must
/// be empty, and over a declaration written for the purpose that carries one instance of every
/// defect it is supposed to find. The five mirrors it measures against — the domain stamp, the role
/// stamp, the revision stamp, the cluster-profile stamp and the app-toggle stamp — are driven
/// separately over planted paths, because a mirror that has drifted from the step it mirrors would
/// let this whole file agree with the declaration about something untrue.
void main() {
  final Directory scratch = Directory.systemTemp.createTempSync('hostyour-branch-');
  final SourceTree tree = repositoryTree();
  final String? text = tree.textOf(declarationFile);
  final BranchClassAudit audit = BranchClassAudit(
    tree: tree,
    declaration: ClassDeclaration.parse(text ?? ''),
    scratch: scratch,
  );

  tearDownAll(() => scratch.deleteSync(recursive: true));

  group('the repository', () {
    test('carries the declaration at all', () {
      expect(
        text,
        isNotNull,
        reason:
            'without it every path of this tree is unclassified and nothing below decides '
            'anything',
      );
    });

    test('has a class for every tracked path', () {
      expect(audit.pathsWithoutAClass(), isEmpty);
    });

    test('has a tracked path for every rule, or a trunk-absent row saying why not', () {
      expect(audit.rulesThatOwnNothing(), isEmpty);
    });

    test('classifies nothing as mixed', () {
      expect(audit.mixedPaths(), isEmpty);
    });

    test('writes a word every section allows', () {
      expect(audit.unreadableWords(), isEmpty);
    });

    test('keeps every trunk-absent rule off the trunk, at the class it fixes', () {
      expect(audit.trunkAbsentDisagreements(), isEmpty);
    });

    test('tracks nothing an outside rule owns', () {
      expect(audit.outsideRulesThatAreTracked(), isEmpty);
    });

    test('declares exactly the paths the domain stamp rewrites', () {
      final List<BranchClassFinding> found = audit.stampDisagreements();
      expect(found, isEmpty, reason: found.join('\n'));
    });

    test(
      'keeps every never-stamp path out of the stamp\'s reach, with the placeholder planted',
      () {
        final List<BranchClassFinding> found = audit.neverStampDisagreements();
        expect(found, isEmpty, reason: found.join('\n'));
      },
    );

    test('grants a derived licence for exactly what the role stamp prunes', () {
      final List<BranchClassFinding> found = audit.derivedDisagreements();
      expect(found, isEmpty, reason: found.join('\n'));
    });

    test('grants "always" over every path a step of the branch program writes again', () {
      final List<BranchClassFinding> found = audit.regeneratedPathsWithoutALicence();
      expect(found, isEmpty, reason: found.join('\n'));
    });
  });

  group('the domain stamp mirror', () {
    // Everything the stamped: and never-stamp: halves decide rests on this answering the way
    // StampFqdn answers. A mirror that has lost an exclusion reports a file that is safe; one that
    // has gained a rule passes over installation state nobody wrote down.

    const DomainStamp stamp = DomainStamp();
    late SourceTree planted;

    setUp(() {
      planted = SourceTree.planted(
        Directory('${scratch.path}${Platform.pathSeparator}stamp-mirror')
          ..createSync(recursive: true),
        <String, String>{
          'cluster/values/planted.yaml': 'domain: ${DomainStamp.placeholder}',
          'apps/planted/templates/deep.yaml': 'host: ${DomainStamp.placeholder}',
          'templates/planted/values.yaml': 'domain: ${DomainStamp.placeholder}',
          'docs/planted.yaml': 'domain: ${DomainStamp.placeholder}',
          'branch-classes.yaml': 'quoted: ${DomainStamp.placeholder}',
          'planted.sh': 'GUARD=${DomainStamp.placeholder}',
          'planted-hashbang': '#!/usr/bin/env bash\nGUARD=${DomainStamp.placeholder}',
          'carries-nothing.yaml': 'a: b',
        },
      );
    });

    test('a values file carrying the placeholder is selected', () {
      expect(stamp.selectionIn(planted), contains('cluster/values/planted.yaml'));
    });

    test('a file that does not carry it is not', () {
      expect(stamp.selectionIn(planted), isNot(contains('carries-nothing.yaml')));
    });

    test('a chart\'s own templates/ is excluded as well as the one at the top', () {
      expect(
        stamp.selectionIn(planted),
        isNot(contains('apps/planted/templates/deep.yaml')),
        reason:
            'the exclusion is a path SEGMENT, and a chart keeps product material several '
            'levels down under the same word',
      );
    });

    test('the scaffold, the docs and the declaration itself are excluded', () {
      expect(
        stamp.selectionIn(planted),
        isNot(
          anyOf(
            contains('templates/planted/values.yaml'),
            contains('docs/planted.yaml'),
            contains(declarationFile),
          ),
        ),
      );
    });

    test('a script is excluded by its suffix and by its first line alike', () {
      expect(
        stamp.selectionIn(planted),
        isNot(anyOf(contains('planted.sh'), contains('planted-hashbang'))),
        reason:
            'the placeholder inside a script is a guard, a fixture or a comment and never '
            'installation state: one script whose own guard compared against it came out refusing '
            'the very domain it was being installed for, and a suffix list alone let an '
            'extensionless script through',
      );
    });
  });

  group('the role stamp mirror', () {
    // The derived: half rests on this answering the way StampRole answers, and the difference
    // between two of its four licences is one file: the branch's own cluster map.

    const String ownMap = BranchClassAudit.ownClusterMap;
    const String foreignMap = 'clusters/active/s1.$placeholderDomain.yaml';

    DerivedLicence? licenceFor(String path, String stage, ClusterRole role) {
      final PruneVerdict verdict = RoleStamp(
        stage: stage,
        role: role,
        ownMap: ownMap,
      ).verdictOn(path);
      return switch (verdict) {
        Pruned(:final DerivedLicence licence) => licence,
        Kept() => null,
      };
    }

    test('a foreign stage takes its platform values, its manifest tree and its app overrides', () {
      expect(
        licenceFor('platform/values-test.yaml', 'dev', ClusterRole.master),
        DerivedLicence.otherStages,
      );
      expect(
        licenceFor('argocd/prod/apps/applicationset.yaml', 'dev', ClusterRole.master),
        DerivedLicence.otherStages,
      );
      expect(
        licenceFor('apps/manager/values-prod.yaml', 'dev', ClusterRole.master),
        DerivedLicence.otherStages,
      );
    });

    test('this installation\'s own stage stays', () {
      expect(licenceFor('apps/manager/values-dev.yaml', 'dev', ClusterRole.master), isNull);
    });

    test('a chart\'s own templates/ is never read as a stage file', () {
      expect(
        licenceFor('apps/manager/templates/values-prod.yaml', 'dev', ClusterRole.master),
        isNull,
        reason:
            'the pattern is apps/<one level>/values-<stage>.yaml, and product material a chart '
            'keeps under templates/ is shipped to every installation',
      );
    });

    test('the books go on a role without the master part and stay on one with it', () {
      const String registration = 'registrations/probe-unit/build.yaml';
      expect(licenceFor(registration, 'dev', ClusterRole.slave), DerivedLicence.booksBranchOnly);
      expect(licenceFor(registration, 'dev', ClusterRole.master), isNull);
    });

    test('a slave keeps its own map and loses every other', () {
      expect(licenceFor(foreignMap, 'dev', ClusterRole.slave), DerivedLicence.foreignMapOnly);
      expect(
        licenceFor(ownMap, 'dev', ClusterRole.slave),
        isNull,
        reason:
            'the branch\'s own map is what the pruning was decided from, so nothing '
            'regenerates it and resolving a conflict in it toward the pin would lose the only '
            'statement of what that cluster is',
      );
    });
  });

  group('the revision stamp mirror', () {
    // The `always` licence over the manifest tree rests on this. StampRevision's own apply touches
    // only the lines naming the trunk; what makes the whole directory derived is its undo, which
    // restores all of it, and StampRole taking the two foreign stage trees with it.

    const RevisionStamp stamp = RevisionStamp();

    test('the trunk carries the tree the step writes', () {
      expect(
        tree.pathsUnder(RevisionStamp.tree),
        isNotEmpty,
        reason: 'a mirror true only of a directory this tree does not carry decides nothing',
      );
    });

    test('a manifest under the tree is written again', () {
      expect(stamp.regenerates('argocd/dev/apps/applicationset.yaml'), isTrue);
    });

    test('a path outside the tree is not', () {
      expect(stamp.regenerates('apps/manager/values-dev.yaml'), isFalse);
      expect(
        stamp.regenerates('argocd-of-something-else/x.yaml'),
        isFalse,
        reason: 'what is named is a directory, not a string a path happens to begin with',
      );
    });
  });

  group('the cluster profile stamp mirror', () {
    const ClusterProfileStamp stamp = ClusterProfileStamp();

    test('the trunk carries the file the step renders', () {
      expect(
        tree.holds(ClusterProfileStamp.profile),
        isTrue,
        reason:
            'the step\'s undo is a git checkout of that path, so a trunk without it would leave a '
            'branch with no file that every chart\'s render requires',
      );
    });

    test('the profile is written again and a toggle beside it is not', () {
      expect(stamp.regenerates(ClusterProfileStamp.profile), isTrue);
      expect(stamp.regenerates('cluster/apps/registry.yaml'), isFalse);
    });
  });

  group('the app toggle stamp mirror', () {
    // Nine of the toggles and not the directory, and that is the whole of what this mirror is for:
    // a licence over cluster/apps/* would hand the seven nobody stamps to the pin as well.

    const AppToggleStamp stamp = AppToggleStamp();

    test('the trunk carries a toggle for every application the step decides', () {
      expect(
        <String>[
          for (final String app in AppToggleStamp.decided)
            if (!tree.holds(AppToggleStamp.pathOf(app))) app,
        ],
        isEmpty,
        reason:
            'the step blocks on a toggle it decides and cannot find, because the ApplicationSet '
            'matches on that file — the application would reach no cluster however a run answered',
      );
    });

    test('a toggle the step decides is written again', () {
      expect(stamp.regenerates('cluster/apps/registry.yaml'), isTrue);
      expect(stamp.regenerates('cluster/apps/observability.yaml'), isTrue);
      expect(stamp.regenerates('cluster/apps/observability-agent.yaml'), isTrue);
    });

    test('the toggles the step does not decide are left to the operator', () {
      final List<String> undecided = <String>[
        for (final String path in tree.pathsUnder('cluster/apps'))
          if (!stamp.regenerates(path)) path,
      ];
      expect(
        undecided,
        containsAll(<String>['cluster/apps/dbgate.yaml', 'cluster/apps/postfix.yaml']),
        reason:
            'whether this installation wants a database browser or a mail relay is a decision made '
            'ON the branch, and a licence over the directory would resolve it away toward the pin '
            'with nothing to write it back',
      );
    });

    test('a path outside the toggles is not written again', () {
      expect(stamp.regenerates('cluster/profile.yaml'), isFalse);
      expect(stamp.regenerates('apps/registry/values-dev.yaml'), isFalse);
    });
  });

  group('counter-probe', () {
    // The same audit over a declaration carrying one instance of every defect. A shape that does
    // not come back here is a measurement that cannot go red, which reads exactly like one that
    // passed.

    late List<BranchClassFinding> found;

    setUpAll(() {
      final Directory probeRoot = Directory('${scratch.path}${Platform.pathSeparator}probe')
        ..createSync(recursive: true);
      final SourceTree probe = SourceTree.planted(probeRoot, <String, String>{
        'kept.yaml': 'a: b',
        'orphan.yaml': 'a: b',
        'mixed.yaml': 'a: b',
        'cluster/values/planted.yaml': 'a: b',
        'outside/planted.txt': 'a: b',
        'guard.yaml': 'a: b',
        'stamped/one.yaml': 'domain: ${DomainStamp.placeholder}',
        'stamped/two.yaml': 'a: b',
        'stampable.yaml': 'domain: ${DomainStamp.placeholder}',
        'platform/values-test.yaml': 'a: b',
        'apps/probe/values-prod.yaml': 'a: b',
        'cluster/profile.yaml': 'global: {}',
      });
      found = BranchClassAudit(
        tree: probe,
        declaration: ClassDeclaration.parse(_declarationCarryingEveryDefect),
        scratch: probeRoot,
      ).findings();
    });

    void reports<T extends BranchClassFinding>(String what, [Matcher? and]) {
      test(what, () {
        expect(found, contains(and == null ? isA<T>() : allOf(isA<T>(), and)));
      });
    }

    reports<PathWithoutAClass>(
      'a tracked path no rule owns',
      predicate<BranchClassFinding>(
        (BranchClassFinding f) => f is PathWithoutAClass && f.path == 'orphan.yaml',
      ),
    );
    reports<RuleOwnsNothing>(
      'a class rule that owns nothing and trunk-absent does not excuse',
      predicate<BranchClassFinding>(
        (BranchClassFinding f) => f is RuleOwnsNothing && f.pattern == 'never/matches/*',
      ),
    );
    reports<PathIsMixed>('a path classified mixed, with no uncertain row for it');
    reports<UnreadableWord>('a word no section allows');
    reports<TrunkCarriesAnAbsentRule>('a trunk-absent rule that owns a path here after all');
    reports<TrunkAbsentClassDisagrees>('a trunk-absent rule whose class disagrees with its branch');
    reports<OutsideRuleIsTracked>('a rule held outside git that owns a tracked path');
    reports<StampReachesAnUndeclaredPath>(
      'a path the domain stamp rewrites that stamped: does not declare',
      predicate<BranchClassFinding>(
        (BranchClassFinding f) => f is StampReachesAnUndeclaredPath && f.path == 'stampable.yaml',
      ),
    );
    reports<StampMissesADeclaredPath>('a stamped path the domain stamp does not reach');
    reports<StampedPathIsNotInstallationState>('a stamped path classified product');
    reports<NeverStampPathIsReachable>(
      'a never-stamp path the stamp reaches once the placeholder is planted in it',
    );
    reports<PrunedPathIsNotDerived>('a path the role stamp prunes that no derived rule owns');
    reports<DerivedLicenceDisagrees>('a derived licence that is not the axis the prune came from');
    reports<AlwaysWithoutAWriter>('an always licence over a path no stamper regenerates');
    reports<RegeneratedPathIsNotDerived>(
      'a path a stamper writes again that no always licence covers',
      predicate<BranchClassFinding>(
        (BranchClassFinding f) =>
            f is RegeneratedPathIsNotDerived && f.path == ClusterProfileStamp.profile,
      ),
    );

    test('a never-stamp section that plants nothing is reported', () {
      final Directory bare = Directory('${scratch.path}${Platform.pathSeparator}bare')
        ..createSync(recursive: true);
      final SourceTree tree = SourceTree.planted(bare, <String, String>{'kept.yaml': 'a: b'});
      final BranchClassAudit audit = BranchClassAudit(
        tree: tree,
        declaration: ClassDeclaration.parse(
          'classes:\n  "*": product\nnever-stamp:\n  "no/such/path": illustration\n',
        ),
        scratch: bare,
      );
      expect(
        audit.neverStampDisagreements(),
        <Matcher>[isA<NeverStampPlantedNothing>()],
        reason:
            'a half that plants nothing is green for having measured nothing, which is the shape '
            'four checks in a sibling repository were silently in for weeks',
      );
    });
  });
}

/// A declaration carrying one instance of every defect the audit is supposed to find.
const String _declarationCarryingEveryDefect = '''
classes:
  "kept.yaml": product
  "mixed.yaml": mixed
  "cluster/profile.yaml": install
  "cluster/values/*": install
  "outside/*": product
  "guard.yaml": product
  "stamped/one.yaml": product
  "stamped/two.yaml": install
  "stampable.yaml": install
  "platform/values-test.yaml": product
  "apps/*/values-prod.yaml": product
  "never/matches/*": product
  "absent/*": product
  "weird/*": product
  "typo.yaml": producr
stamped:
  "stamped/one.yaml": global.domain
  "stamped/two.yaml": global.domain
never-stamp:
  "guard.yaml": illustration
derived:
  "cluster/values/*": always
  "platform/values-test.yaml": books-branch-only
  "nothing/*": other-stages
trunk-absent:
  "cluster/values/*": install-branch
  "absent/*": install-branch
  "weird/*": sideways
uncertain: {}
outside:
  "outside/*": product
''';
