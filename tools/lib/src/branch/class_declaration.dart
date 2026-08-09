import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import '../tree/glob_pattern.dart';
import 'branch_class.dart';
import 'derived_licence.dart';

/// branch-classes.yaml, read.
///
/// ORDER IS THE MECHANISM of the classes section — first match owns the path and later rules never
/// see it — so the rules are a list in document order and never a map that somebody might sort. A
/// specific path stands ABOVE the glob it is an exception to, and a rule accidentally placed below
/// its own glob owns nothing, which is what makes it visible as dead.
@immutable
final class ClassDeclaration {
  const ClassDeclaration._({
    required this.classes,
    required this.unreadableClassWords,
    required this.stamped,
    required this.neverStamp,
    required this.derived,
    required this.unreadableDerivedWords,
    required this.trunkAbsent,
    required this.uncertain,
    required this.outside,
    required this.sections,
  });

  /// The declaration written as [text].
  factory ClassDeclaration.parse(String text) {
    final Object? document = loadYaml(text);
    final YamlMap root = document is YamlMap ? document : YamlMap();

    final List<ClassRule> classes = <ClassRule>[];
    final Map<String, String> unreadableClasses = <String, String>{};
    for (final MapEntry<String, String> row in _rowsOf(root, 'classes').entries) {
      final BranchClass? declared = BranchClass.tryParse(row.value);
      if (declared == null) {
        unreadableClasses[row.key] = row.value;
      } else {
        classes.add(ClassRule(pattern: GlobPattern(row.key), declared: declared));
      }
    }

    final List<DerivedRule> derived = <DerivedRule>[];
    final Map<String, String> unreadableDerived = <String, String>{};
    for (final MapEntry<String, String> row in _rowsOf(root, 'derived').entries) {
      final DerivedLicence? licence = DerivedLicence.tryParse(row.value);
      if (licence == null) {
        unreadableDerived[row.key] = row.value;
      } else {
        derived.add(DerivedRule(pattern: GlobPattern(row.key), licence: licence));
      }
    }

    return ClassDeclaration._(
      classes: classes,
      unreadableClassWords: unreadableClasses,
      stamped: _rowsOf(root, 'stamped'),
      neverStamp: _rowsOf(root, 'never-stamp'),
      derived: derived,
      unreadableDerivedWords: unreadableDerived,
      trunkAbsent: <String, TrunkAbsentSide>{
        for (final MapEntry<String, String> row in _rowsOf(root, 'trunk-absent').entries)
          row.key: TrunkAbsentSide.of(row.value),
      },
      uncertain: _rowsOf(root, 'uncertain'),
      outside: _rowsOf(root, 'outside'),
      sections: <String>{
        for (final Object? key in root.keys)
          if (key is String) key,
      },
    );
  }

  /// Every rule of the classes section, in document order.
  final List<ClassRule> classes;

  /// The rows of the classes section whose word names no class, against that word.
  final Map<String, String> unreadableClassWords;

  /// The paths whose domain placeholder IS installation state, against the key that is stamped.
  final Map<String, String> stamped;

  /// The paths whose domain placeholder is a guard, a fixture, an illustration or the
  /// documentation of the stamp itself, against which of those it is.
  final Map<String, String> neverStamp;

  /// Every rule of the derived section, in document order.
  final List<DerivedRule> derived;

  /// The rows of the derived section whose word names no licence, against that word.
  final Map<String, String> unreadableDerivedWords;

  /// The rules that legitimately own no tracked path here, against the branch they stand on.
  final Map<String, TrunkAbsentSide> trunkAbsent;

  /// What the classification could not settle, against what is unresolved.
  final Map<String, String> uncertain;

  /// What is held deliberately outside git, against the class it would carry if it were tracked.
  final Map<String, String> outside;

  /// The names of the sections the file carries, in document order.
  final Set<String> sections;

  /// The rule that owns [path] — the FIRST that matches — or null when no rule does.
  ClassRule? ownerOf(String path) {
    for (final ClassRule rule in classes) {
      if (rule.pattern.matches(path)) {
        return rule;
      }
    }
    return null;
  }

  /// The derived rule that owns [path] — the first that matches — or null when none does.
  DerivedRule? derivedRuleFor(String path) {
    for (final DerivedRule rule in derived) {
      if (rule.pattern.matches(path)) {
        return rule;
      }
    }
    return null;
  }

  static Map<String, String> _rowsOf(YamlMap root, String section) {
    final Object? node = root[section];
    if (node is! YamlMap) {
      return const <String, String>{};
    }
    final Map<String, String> rows = <String, String>{};
    for (final MapEntry<Object?, Object?> entry in node.entries) {
      final Object? key = entry.key;
      final Object? value = entry.value;
      if (key is String && value is String) {
        rows[key] = value;
      }
    }
    return rows;
  }
}

/// One row of the classes section.
@immutable
final class ClassRule {
  /// The rule saying that [pattern] is [declared].
  const ClassRule({required this.pattern, required this.declared});

  /// What it owns.
  final GlobPattern pattern;

  /// What it says those paths are.
  final BranchClass declared;
}

/// One row of the derived section.
@immutable
final class DerivedRule {
  /// The rule granting [licence] over [pattern].
  const DerivedRule({required this.pattern, required this.licence});

  /// What it owns.
  final GlobPattern pattern;

  /// What it permits.
  final DerivedLicence licence;
}

/// Which branch a trunk-absent rule's paths stand on, and so which class it fixes.
enum TrunkAbsentSide {
  /// One cluster's own branch. The rule must be classed install.
  installBranch('install-branch', BranchClass.install),

  /// The branch of the cluster holding the master role, where the books stand. The rule must be
  /// classed books.
  booksBranch('books-branch', BranchClass.books),

  /// A word that is neither, which fixes nothing and is reported.
  unreadable('', BranchClass.mixed);

  const TrunkAbsentSide(this.word, this.fixes);

  /// The word the declaration writes.
  final String word;

  /// The class a rule of this side must carry.
  final BranchClass fixes;

  /// The side [word] names, or [unreadable] when it names neither.
  static TrunkAbsentSide of(String word) {
    for (final TrunkAbsentSide each in TrunkAbsentSide.values) {
      if (each.word == word && each != unreadable) {
        return each;
      }
    }
    return unreadable;
  }
}
