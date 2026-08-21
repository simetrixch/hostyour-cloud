/// appset-read-paths — every path an ApplicationSet of this repository reads that only a branch
/// writer can produce is produced by one.
///
/// **THE DEFECT THIS EXISTS FOR, MEASURED.** `installation/profile.yaml` is loaded LAST in the
/// values chain of every ApplicationSet here, and the trunk carries it saying `global: {}` because
/// the trunk knows no installation. What fills it is a deploy program, on the install branch. Delete
/// the rows that write it and nothing on this side changes: the entry still resolves, because it
/// resolves against the TRACKED tree and the trunk's own empty copy answers. Every Application then
/// renders with no vaultUrl, no domain and no registry, syncs, and reports Healthy.
///
/// That was measured on this tree, by deleting all three write rows at once: the gate reported
/// `00:00 +237: All tests passed!` and `ci: OK — every check green` with seven ApplicationSet entries
/// loading a file no run would produce any more. `chart-paths` cannot see it — the empty trunk copy
/// is a tracked file and answers the path. `appset-written-paths` cannot see it either — it judges
/// the other direction, and a writer that is gone writes nothing to report.
///
/// **WHICH READ PATHS ARE HELD, AND WHY IT IS NOT EVERY ONE.** Most paths an ApplicationSet reads
/// need no branch writer at all: `platform/values-common.yaml` is the product's own and travels
/// byte-identical, `clusters/active/*.yaml` and `registrations/*/build.yaml` stand on the books
/// branch with the Controller as their writer, and `$pins/<chart>/pins-__STAGE__.yaml` is another
/// repository's file. What separates them is not something this check decides: `branch-classes.yaml`
/// is THE single source of truth for what every path of this repository IS, and the class it gives a
/// path — `install`, `product` or `books` — is read out of it. Only an `install` path is held here,
/// because that is the class whose whole content is written per branch and whose trunk copy is
/// therefore never the answer.
///
/// **NOTHING HERE NAMES A PATH.** Every side is read where it is decided:
///
///   * what an ApplicationSet reads — [appsetReadPathsIn], the same reader the sibling check uses,
///     so the two directions cannot come to disagree about what a read is;
///   * what a path IS — [pathClassesIn] over `branch-classes.yaml`, in the first-match order that
///     file declares its rules in;
///   * what a program writes — [writtenPathsIn], the same reader again, off the rows a program
///     writes a file from a template with.
///
/// **WHAT IT DOES NOT REACH.** A read path no rule of `branch-classes.yaml` owns is left alone
/// rather than reported, because a path with no class is a gap in that declaration and not a
/// statement that nothing writes it. One path is unowned today:
/// `$pins/{{ .chart }}/pins-__STAGE__.yaml`, which stands on the catalog's books branch and is no
/// path of this repository at all, so no rule of the `classes:` section can own it.
///
/// It inherits the narrowing of [writtenPathsIn], which reads a write off [writeFileStep] rows
/// alone. A path an `install` entry reads and `fill_key_value_file` or `copy_branch_file` writes
/// would be reported here as written by nothing. No `install` path is written by either step today.
///
/// It reads only the entries that carry a `$<ref>/` prefix, because that is what [appsetReadPathsIn]
/// takes for a path of this repository. A chart-relative entry resolves against its own source's
/// chart directory, which is a place no deploy program writes into, so there is nothing on the
/// writer's side to hold it against.
///
/// It says nothing about CONTENT. A program writing the right path from a template that no longer
/// carries the key an Application needs passes here — what is held is that the two halves name one
/// path.
///
/// It reads the programs of ONE installation tree, the one it is handed, exactly as its sibling
/// does, and `installation_tree.dart` refuses rather than skipping where none is findable.
library;

import 'package:yaml/yaml.dart';

import 'appset_written_paths.dart';

/// The declaration that says what every path of this repository is, at the repository root.
const String branchClassesPath = 'branch-classes.yaml';

/// The section of [branchClassesPath] that gives every path its class.
const String classesSection = 'classes';

/// The class of a path whose content is written per install branch.
///
/// The one class held here: a `product` path travels byte-identical and the trunk IS its answer, a
/// `books` path is never tracked on the trunk and has the Controller for a writer, and only an
/// `install` path is a file whose every byte on a branch came out of a run.
const String installClass = 'install';

/// One rule of the `classes:` section: a pattern, and the class it gives every path it owns.
final class PathClass {
  /// Records that [pattern] gives the paths it owns the class [named].
  const PathClass({required this.pattern, required this.named});

  /// The pattern, exactly as `branch-classes.yaml` spells it.
  final String pattern;

  /// The class it names — `install`, `product`, `books` or `mixed`.
  final String named;
}

/// One path an ApplicationSet reads that no writer of this installation writes.
final class UnwrittenReadPath {
  /// Records that [where] reads [path], which nothing writes, [because].
  const UnwrittenReadPath({required this.where, required this.path, required this.because});

  /// The manifest that reads it, relative to the repository.
  final String where;

  /// The path it reads, as the manifest spells it with its `$<ref>/` prefix dropped.
  final String path;

  /// Why a read nobody answers costs more than a failed sync.
  final String because;

  /// The one line a refusal says about it.
  @override
  String toString() => '$where reads $path — $because';
}

// ── reading the declaration ─────────────────────────────────────────────────

/// Every rule of the `classes:` section of [declaration], in the order it declares them.
///
/// The order is the rule: `branch-classes.yaml` states that the first matching rule OWNS a path and
/// that later rules never see it, which is what puts the seven platform registrations above
/// `registrations/*/build.yaml`. A reader that sorted or set-ified them would give a path the class
/// of whichever rule it happened to try first.
///
/// Empty where the section is not found, which the audit treats as a refusal rather than as "no path
/// has a class": a comparison against an empty declaration would silently hold nothing.
List<PathClass> pathClassesIn(String declaration) {
  final Object? loaded = loadYaml(declaration);
  final Object? classes = loaded is YamlMap ? loaded[classesSection] : null;
  if (classes is! YamlMap) {
    return const <PathClass>[];
  }
  final List<PathClass> rules = <PathClass>[];
  for (final Object? pattern in classes.keys) {
    final Object? named = classes[pattern];
    if (pattern is String && named is String) {
      rules.add(PathClass(pattern: pattern, named: named));
    }
  }
  return rules;
}

/// A value neither side can know: a program's slot, a stamp marker, a render-time action, or a
/// pattern's own star.
final RegExp _wildcard = RegExp(r'\{\{.*?\}\}|<[^<>/]*>|__[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*__|\*');

/// The character a wildcard is folded to before a shape is matched against it — one no path carries,
/// and not the empty string, which would let a shape carrying no wildcard answer a path that does.
const String _folded = '\u0001';

String _literal(String text) => text.replaceAll(_wildcard, _folded);

/// [pattern] as a shape, where `*` crosses `/` as well.
///
/// That is the sense `branch-classes.yaml` states for its own patterns — `charts/*` covers the whole
/// subtree and `*.sh` covers every script wherever it sits — and reading them with a shell's
/// segment-bounded star would hand half the tree to the wrong rule.
RegExp _patternShape(String pattern) => RegExp(
  '^${pattern.splitMapJoin(RegExp(r'\*'), onMatch: (Match each) => '.*', onNonMatch: RegExp.escape)}\$',
);

/// [path] as a shape, where each wildcard stands for one segment's worth of characters.
RegExp _pathShape(String path) => RegExp(
  '^${path.splitMapJoin(_wildcard, onMatch: (Match each) => '[^/]*', onNonMatch: RegExp.escape)}\$',
);

/// Whether the rule [pattern] owns [path], with the wildcards of both sides standing for what
/// neither can know.
///
/// Both directions, because the two sides carry wildcards of different kinds: a rule's `*` is the
/// declaration's own, and a read path's `{{ .name }}`, `__STAGE__` or generator star stands for one
/// segment the manifest cannot name. `installation/values/{{ .name }}.yaml` is owned by the rule
/// `installation/values/manager.yaml` — one entry loads whichever of those files the app it stands
/// for has — and no single direction sees that.
bool patternOwns(String pattern, String path) =>
    _patternShape(pattern).hasMatch(_literal(path)) || _pathShape(path).hasMatch(_literal(pattern));

/// The class [rules] give [path], or null where no rule owns it.
String? classOf(String path, {required List<PathClass> rules}) {
  for (final PathClass rule in rules) {
    if (patternOwns(rule.pattern, path)) {
      return rule.named;
    }
  }
  return null;
}

// ── holding one against the other ───────────────────────────────────────────

/// Every path of [read] whose class is [installClass] and that nothing in [written] produces.
///
/// [read] names, per manifest, the paths that manifest loads or selects on; [written] is every path
/// the deploy programs write into a checkout of this repository; [rules] is the `classes:` section
/// of `branch-classes.yaml`, in its own order.
List<UnwrittenReadPath> auditReadPaths({
  required Map<String, Set<String>> read,
  required Set<String> written,
  required List<PathClass> rules,
}) {
  final List<UnwrittenReadPath> found = <UnwrittenReadPath>[];
  for (final MapEntry<String, Set<String>> manifest in read.entries) {
    for (final String path in manifest.value) {
      if (classOf(path, rules: rules) != installClass) {
        continue;
      }
      if (written.any((String each) => readAnswersWritten(path, each))) {
        continue;
      }
      found.add(
        UnwrittenReadPath(
          where: manifest.key,
          path: path,
          because:
              '$branchClassesPath gives it the class "$installClass" — its content is written per '
              'install branch — and no program of this installation writes it. Nothing goes red '
              'either way: where the trunk carries a copy the entry resolves against that copy, '
              'and where it does not, ignoreMissingValueFiles skips the entry. The Application is '
              'created, syncs, reports Healthy, and the values it names are absent from every '
              'workload the set creates with nothing anywhere saying so.',
        ),
      );
    }
  }
  return found;
}
