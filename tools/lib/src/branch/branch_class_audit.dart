import 'dart:io';

import '../installation.dart';
import '../stamp/app_toggle_stamp.dart';
import '../stamp/cluster_profile_stamp.dart';
import '../stamp/domain_stamp.dart';
import '../stamp/revision_stamp.dart';
import '../stamp/role_stamp.dart';
import '../tree/glob_pattern.dart';
import '../tree/source_tree.dart';
import 'branch_class.dart';
import 'branch_class_finding.dart';
import 'class_declaration.dart';
import 'derived_licence.dart';

/// branch-classes.yaml says what every path of a tree IS, and this is what reads it.
///
/// The file was written because two greps had been deciding it by accident. One stamped the
/// installer's own placeholder guard, so the installer refused the domain it had just installed;
/// the other classified the cluster maps as derived, so a merge conflict would have resolved an
/// installation's ledger away and reported success. A grep cannot know what a path MEANS, so the
/// meaning was written down — and then nothing read it back.
///
/// THE STAMPERS ARE MEASURED AND NOT BELIEVED. `stamped:` and `never-stamp:` are claims about what
/// the domain stamp does; `derived:` is a claim about what the role stamp removes and about what
/// three other steps write again. All five are mirrored in ../stamp/, and the mirrors are
/// themselves driven over planted paths so a mirror that has drifted is a finding rather than a
/// silent agreement between two wrong things.
///
/// A LICENCE IS MEASURED IN BOTH DIRECTIONS, because it decays from either side. A row granting
/// `always` over a path no step writes again is a licence to throw away what only the branch had;
/// a path a step does write again and no row covers is a merge conflict that stops a sync nothing
/// needed stopped. Two rows of this declaration had already decayed the first way, granting
/// `always` on the strength of a program that existed nowhere.
///
/// THE BOOKS ARE PLANTED BY NAME. What `derived:` says about registrations and foreign cluster maps
/// cannot be measured against the trunk, because the trunk carries none of them — the manager
/// writes them onto another branch. They are made concrete from the trunk-absent rules that name
/// them, so the prune has something to reach.
final class BranchClassAudit {
  /// The audit of [tree] against [declaration], with [scratch] to plant into.
  const BranchClassAudit({
    required this.tree,
    required this.declaration,
    required this.scratch,
    this.domainStamp = const DomainStamp(),
  });

  /// The tree being decided about.
  final SourceTree tree;

  /// What it declares about itself.
  final ClassDeclaration declaration;

  /// A directory the never-stamp half may write into. Nothing in the tree is modified.
  final Directory scratch;

  /// The mirror of the step that writes an installation's domain into a branch.
  final DomainStamp domainStamp;

  /// Where the fixture branch's own cluster map stands.
  static const String ownClusterMap = 'clusters/active/$fixtureFqdn.yaml';

  /// The mirror of the step that retargets the manifest tree at this installation's own branch.
  static const RevisionStamp revisionStamp = RevisionStamp();

  /// The mirror of the step that renders the file saying where this installation's services are.
  static const ClusterProfileStamp clusterProfileStamp = ClusterProfileStamp();

  /// The mirror of the step that decides which applications this cluster runs.
  static const AppToggleStamp appToggleStamp = AppToggleStamp();

  /// Everything the declaration claims that is not true of this tree.
  List<BranchClassFinding> findings() => <BranchClassFinding>[
    ...unreadableWords(),
    ...pathsWithoutAClass(),
    ...rulesThatOwnNothing(),
    ...mixedPaths(),
    ...trunkAbsentDisagreements(),
    ...outsideRulesThatAreTracked(),
    ...stampDisagreements(),
    ...neverStampDisagreements(),
    ...derivedDisagreements(),
    ...regeneratedPathsWithoutALicence(),
  ];

  /// Words in a section that name none of the values that section allows.
  List<BranchClassFinding> unreadableWords() => <BranchClassFinding>[
    for (final MapEntry<String, String> row in declaration.unreadableClassWords.entries)
      UnreadableWord(section: 'classes', pattern: row.key, word: row.value),
    for (final MapEntry<String, String> row in declaration.unreadableDerivedWords.entries)
      UnreadableWord(section: 'derived', pattern: row.key, word: row.value),
    for (final MapEntry<String, TrunkAbsentSide> row in declaration.trunkAbsent.entries)
      if (row.value == TrunkAbsentSide.unreadable)
        UnreadableWord(section: 'trunk-absent', pattern: row.key, word: 'neither branch'),
  ];

  /// Tracked paths no rule owns.
  List<BranchClassFinding> pathsWithoutAClass() => <BranchClassFinding>[
    for (final String path in tree.paths)
      if (declaration.ownerOf(path) == null) PathWithoutAClass(path),
  ];

  /// Rules that own nothing and that trunk-absent: does not excuse.
  List<BranchClassFinding> rulesThatOwnNothing() => <BranchClassFinding>[
    for (final ClassRule rule in declaration.classes)
      if (rule.pattern.ownedIn(tree.paths).isEmpty &&
          !declaration.trunkAbsent.containsKey(rule.pattern.source))
        RuleOwnsNothing(section: 'classes', pattern: rule.pattern.source),
  ];

  /// Paths declared mixed, which the declaration calls a defect in itself.
  List<BranchClassFinding> mixedPaths() => <BranchClassFinding>[
    for (final ClassRule rule in declaration.classes)
      if (rule.declared == BranchClass.mixed)
        PathIsMixed(
          pattern: rule.pattern.source,
          hasUncertainRow: declaration.uncertain.containsKey(rule.pattern.source),
        ),
  ];

  /// trunk-absent rules that own a path here, or whose class disagrees with the branch they name.
  List<BranchClassFinding> trunkAbsentDisagreements() {
    final List<BranchClassFinding> found = <BranchClassFinding>[];
    for (final MapEntry<String, TrunkAbsentSide> row in declaration.trunkAbsent.entries) {
      final ClassRule? rule = _ruleNamed(row.key);
      final List<String> owned = <String>[
        for (final String path in tree.paths)
          if (declaration.ownerOf(path)?.pattern.source == row.key) path,
      ];
      if (owned.isNotEmpty) {
        found.add(TrunkCarriesAnAbsentRule(pattern: row.key, paths: owned));
      }
      if (row.value == TrunkAbsentSide.unreadable) {
        continue;
      }
      if (rule == null || rule.declared != row.value.fixes) {
        found.add(
          TrunkAbsentClassDisagrees(
            pattern: row.key,
            expected: row.value.fixes,
            declared: rule?.declared,
          ),
        );
      }
    }
    return found;
  }

  /// outside rules that own a tracked path.
  List<BranchClassFinding> outsideRulesThatAreTracked() => <BranchClassFinding>[
    for (final String pattern in declaration.outside.keys)
      for (final String path in GlobPattern(pattern).ownedIn(tree.paths))
        OutsideRuleIsTracked(pattern: pattern, path: path),
  ];

  /// The stamped section, in both directions against the domain stamp.
  List<BranchClassFinding> stampDisagreements() {
    final List<String> reached = domainStamp.selectionIn(tree);
    return <BranchClassFinding>[
      for (final String path in reached)
        if (!declaration.stamped.containsKey(path)) StampReachesAnUndeclaredPath(path),
      for (final String path in declaration.stamped.keys) ...<BranchClassFinding>[
        if (!reached.contains(path)) StampMissesADeclaredPath(path),
        if (_stampedClassOf(path) case final BranchClassFinding wrong) wrong,
      ],
    ];
  }

  /// The never-stamp section, measured by PLANTING the placeholder rather than by searching for it.
  ///
  /// A guard that does not carry the placeholder today would pass a search and still be inside the
  /// stamp's reach tomorrow, which is the failure this shape exists to prevent: the copy is written
  /// with the placeholder appended, and the stamp is then run over the copy.
  List<BranchClassFinding> neverStampDisagreements() {
    final Map<String, String> planted = <String, String>{};
    final Map<String, String> ownedBy = <String, String>{};
    for (final String pattern in declaration.neverStamp.keys) {
      for (final String path in GlobPattern(pattern).ownedIn(tree.paths)) {
        final String? text = tree.textOf(path);
        if (text == null) {
          continue;
        }
        planted[path] = '$text\n# planted: ${DomainStamp.placeholder}\n';
        ownedBy[path] = pattern;
      }
    }
    if (planted.isEmpty) {
      return const <BranchClassFinding>[NeverStampPlantedNothing()];
    }
    final SourceTree plantedTree = SourceTree.planted(
      Directory('${scratch.path}${Platform.pathSeparator}never-stamp')..createSync(recursive: true),
      planted,
    );
    return <BranchClassFinding>[
      for (final String path in domainStamp.selectionIn(plantedTree))
        NeverStampPathIsReachable(pattern: ownedBy[path] ?? '?', path: path),
    ];
  }

  /// The derived section, against what the role stamp really prunes and what a stamper regenerates.
  List<BranchClassFinding> derivedDisagreements() {
    final List<BranchClassFinding> found = <BranchClassFinding>[];
    final Set<String> reached = <String>{};
    final Set<String> saidAlready = <String>{};

    for (final String stage in stages) {
      for (final ClusterRole role in ClusterRole.values) {
        final RoleStamp stamp = RoleStamp(stage: stage, role: role, ownMap: ownClusterMap);
        for (final String path in <String>[...tree.paths, ..._plantedBooks]) {
          final PruneVerdict verdict = stamp.verdictOn(path);
          if (verdict is! Pruned) {
            continue;
          }
          final DerivedRule? rule = declaration.derivedRuleFor(path);
          if (rule == null) {
            if (saidAlready.add('unowned:$path')) {
              found.add(
                PrunedPathIsNotDerived(
                  path: path,
                  stage: stage,
                  role: role,
                  licence: verdict.licence,
                ),
              );
            }
            continue;
          }
          reached.add(rule.pattern.source);
          // `always` is the widest licence the section has — every stage, both roles — so a prune
          // falls inside it rather than disagreeing with it. Only a narrower licence has to name
          // the axis the prune really came from.
          if (rule.licence == DerivedLicence.always || rule.licence == verdict.licence) {
            continue;
          }
          if (saidAlready.add('${rule.pattern.source}/${verdict.licence.word}')) {
            found.add(
              DerivedLicenceDisagrees(
                pattern: rule.pattern.source,
                granted: rule.licence,
                actual: verdict.licence,
                example: path,
              ),
            );
          }
        }
      }
    }

    for (final DerivedRule rule in declaration.derived) {
      if (rule.licence == DerivedLicence.always) {
        // The widest licence there is, so it is the one that has to name a writer. A rule owning a
        // path no step writes again licences a sync to resolve that path toward the pin and lose
        // whatever only the branch had in it.
        for (final String path in rule.pattern.ownedIn(tree.paths)) {
          if (!regeneratedByAStamper(path)) {
            found.add(AlwaysWithoutAWriter(pattern: rule.pattern.source, path: path));
            break;
          }
        }
        continue;
      }
      if (!reached.contains(rule.pattern.source)) {
        found.add(RuleOwnsNothing(section: 'derived', pattern: rule.pattern.source));
      }
    }
    return found;
  }

  /// Paths a step writes again on every run that no derived rule grants `always` over.
  List<BranchClassFinding> regeneratedPathsWithoutALicence() => <BranchClassFinding>[
    for (final String path in tree.paths)
      if (regeneratedByAStamper(path) &&
          declaration.derivedRuleFor(path)?.licence != DerivedLicence.always)
        RegeneratedPathIsNotDerived(path),
  ];

  /// Whether some step of the branch program writes [path] again on every run, at every stage and
  /// under both roles — which is exactly what the `always` licence rests on.
  ///
  /// Three steps do, and they are named rather than pattern-matched: a fourth arriving in
  /// simetrixch/ansiwise-plugins has to be mirrored here before its paths may carry the licence.
  bool regeneratedByAStamper(String path) =>
      revisionStamp.regenerates(path) ||
      clusterProfileStamp.regenerates(path) ||
      appToggleStamp.regenerates(path);

  /// The books paths the trunk does not carry, made concrete from the rules that name them.
  ///
  /// The cluster-map rule gets two, because [DerivedLicence.foreignMapOnly] is exactly the
  /// difference between the branch's own map and any other.
  List<String> get _plantedBooks => <String>[
    for (final MapEntry<String, TrunkAbsentSide> row in declaration.trunkAbsent.entries)
      if (row.value == TrunkAbsentSide.booksBranch)
        if (row.key.startsWith('clusters/active/')) ...<String>[
          ownClusterMap,
          'clusters/active/s1.$placeholderDomain.yaml',
        ] else
          GlobPattern(row.key).concreteWith('probe-unit'),
  ];

  BranchClassFinding? _stampedClassOf(String path) {
    final ClassRule? rule = declaration.ownerOf(path);
    if (rule == null) {
      return StampedPathIsNotInstallationState(path: path, rule: null, declared: null);
    }
    if (rule.declared == BranchClass.install || rule.declared == BranchClass.mixed) {
      return null;
    }
    return StampedPathIsNotInstallationState(
      path: path,
      rule: rule.pattern.source,
      declared: rule.declared,
    );
  }

  ClassRule? _ruleNamed(String pattern) {
    for (final ClassRule rule in declaration.classes) {
      if (rule.pattern.source == pattern) {
        return rule;
      }
    }
    return null;
  }
}
