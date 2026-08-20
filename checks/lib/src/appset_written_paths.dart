/// appset-written-paths — every path a deploy program writes into a checkout of this repository is
/// a path an ApplicationSet of this repository reads.
///
/// **THE DEFECT THIS EXISTS FOR, MEASURED.** These files are named in three repositories at once: a
/// deploy program writes `installation/profile.yaml` into the cluster's checkout, every
/// ApplicationSet here loads it LAST in its values chain, and the Controller reads the same chain
/// through its own `clusterValueChainPaths`. Rename it in this repository and in the Controller and
/// leave the deploy program writing the old name, and the branch carries BOTH files: the trunk's
/// copy at the new name, which says `global: {}` because the trunk knows no installation, and the
/// run's rendered copy at the old name, which nothing loads. Every Application then renders with no
/// vaultUrl, no domain and no registry — and the old name still resolves in the tracked tree, so
/// `chart-paths` passes, `appset-cluster-map-keys` passes and every other check here passes with
/// them. That was measured on this tree before this check was written: 215 green, with the profile
/// every chart depends on written to a path nothing reads.
///
/// The reverse drift — a path an ApplicationSet READS that no writer writes — is `appset-read-paths`
/// beside this one, and it needed its own check: `chart-paths` resolves a `$<ref>/` path against the
/// TRACKED tree, and the trunk's own `installation/profile.yaml` answers it whether a program writes
/// the branch copy or not. Measured by deleting all three rows that write that file — the whole gate
/// reported `+237: All tests passed!` and `ci: OK — every check green` with seven ApplicationSet
/// entries loading a file no run would produce any more.
///
/// **NOTHING HERE NAMES A PATH OR A CHECKOUT.** Both sides are read where they are decided:
///
///   * which checkouts are of THIS repository — [platformCheckoutRootsIn], out of the roots a
///     program stamps a TRACKED TREE of this repository in. A program that stamps `argocd` in
///     `/srv/hostyour-cloud` is working in a checkout of this repository and says so by doing it;
///     the tenant catalog's checkout and the machine's own `/etc` are named by nothing here and
///     fall out on their own.
///   * what a program writes there — [writtenPathsIn], off the `path:` of its [writeFileStep] rows,
///     made relative to the root it writes into.
///   * what an ApplicationSet reads — [appsetReadPathsIn], the `valueFiles` entries and the
///     generator globs of every manifest, with a `$<ref>/` prefix dropped.
///
/// **A SLOT, A MARKER AND A RENDER-TIME ACTION ALL STAND AS ONE WILDCARD.** `<fqdn>`, `__STAGE__`
/// and `{{ .name }}` are values this check cannot know, and they stand on both sides of the same
/// comparison — a program writes `clusters/active/<fqdn>.yaml` and a generator selects
/// `clusters/active/*.yaml`, a program writes `installation/values/postfix.yaml` and an
/// ApplicationSet loads `$values/installation/values/{{ .name }}.yaml`. Each stands for any single
/// segment's worth of characters, and a written path is answered when a read path's shape matches
/// it.
///
/// **WHAT IT DOES NOT REACH.** It judges ONE direction: a written path nothing reads. A path an
/// ApplicationSet reads is not held here at all — `appset-read-paths` holds that direction, and
/// `chart-paths` holds whether the tracked tree answers it.
///
/// It counts a write by ONE step, [writeFileStep], and two other steps put a file into the very
/// checkouts this check calls checkouts of this repository: `fill_key_value_file` writes
/// `configs/config.<stage>` and `secrets/secrets.<stage>` into `/srv/hostyour-cloud`, and
/// `copy_branch_file` writes `configs/config.<stage>` into `/srv/hostyour-cloud-slave`. Neither is
/// counted, and that narrowing is LOAD-BEARING for a green run rather than an incidental detail:
/// change the `fill_key_value_file` row writing `configs/config.<stage>` to [writeFileStep] — one
/// word, the same path — and this check refuses over `configs/config.<stage>`, because no
/// ApplicationSet of this repository loads a config file. So a green run here says every path a
/// program writes FROM A TEMPLATE is read, and says nothing about what the other two steps write.
///
/// A `$<ref>/` prefix is DROPPED rather than resolved to the source carrying the ref, so a read
/// entry pointing into another repository — `$pins/<chart>/pins-__STAGE__.yaml`, which stands on the
/// catalog's books branch — counts here as a read of this repository. A written path answered only
/// by such an entry would pass. No path any program writes has that shape today, and the day one
/// does, this check calls it read when it is not.
///
/// It reads the programs of ONE installation tree, the one it is handed. An installation whose
/// programs stand where this suite does not look is not judged at all, which is what the refusal in
/// `installation_tree.dart` exists to make loud rather than silent.
///
/// It says nothing about CONTENT or POSITION. A program writing the right path from the wrong
/// template, and an ApplicationSet loading the right file at the wrong place in its values chain,
/// both pass here — what is held is that the two halves name one path.
library;

import 'package:yaml/yaml.dart';

/// The step a program writes a file FROM A TEMPLATE with, which is the one step this check reads a
/// write off.
///
/// Not the only step that puts a file into a checkout of this repository — the limits paragraph
/// above names the two others and what leaving them out costs.
const String writeFileStep = 'write_file_from_template';

/// The step a program stamps a tracked tree of a checkout with.
///
/// This is what identifies a checkout as one of THIS repository: the step names the directory it
/// rewrites, and a directory this repository tracks is one only a checkout of this repository has.
const String stampTreeStep = 'stamp_placeholder_in_tracked_files';

/// One path a program writes that no ApplicationSet of this repository reads.
final class UnreadWrittenPath {
  /// Records that [where] writes [path], which nothing reads, [because].
  const UnreadWrittenPath({required this.where, required this.path, required this.because});

  /// The program that writes it, as the installation tree names it.
  final String where;

  /// The path it writes, relative to the checkout it writes into.
  final String path;

  /// Why a file nothing loads costs more than a missing one.
  final String because;

  /// The one line a refusal says about it.
  @override
  String toString() => '$where writes $path — $because';
}

// ── reading the two sides ───────────────────────────────────────────────────

YamlMap? _document(String yaml) {
  final Object? loaded = loadYaml(yaml);
  return loaded is YamlMap ? loaded : null;
}

Iterable<YamlMap> _stepsIn(String program) {
  final Object? steps = _document(program)?['steps'];
  return steps is YamlList ? steps.whereType<YamlMap>() : const <YamlMap>[];
}

String _withoutTrailingSlash(String path) =>
    path.endsWith('/') ? path.substring(0, path.length - 1) : path;

/// Every checkout of this repository that [program] works in, as the roots it stamps one of
/// [directories] in.
///
/// [directories] is every top-level directory this repository tracks. A [stampTreeStep] row names
/// both the checkout it runs in and the tree inside it that it rewrites, so a root paired with a
/// tree this repository carries is a checkout of this repository — said by the program's own work
/// rather than by a name written here. An installation keeps more than one such checkout at a time,
/// which is why this is a set: a master's own, and the one it prepares a slave's branch in.
Set<String> platformCheckoutRootsIn(String program, {required Set<String> directories}) {
  final Set<String> roots = <String>{};
  for (final YamlMap step in _stepsIn(program)) {
    if (step['step'] != stampTreeStep) {
      continue;
    }
    final Object? repository = step['repository'];
    final Object? tree = step['tree'];
    if (repository is String && tree is String && directories.contains(tree)) {
      roots.add(_withoutTrailingSlash(repository));
    }
  }
  return roots;
}

/// Every path [program] writes into one of [roots], relative to the root it writes into.
///
/// A row writing outside every root — the machine's own network units, a manifest staged in `/tmp`,
/// the tenant catalog's checkout — is not a file of this repository and is passed over rather than
/// reported: what it writes is answered by whoever reads it, and that reader is not an
/// ApplicationSet here.
Set<String> writtenPathsIn(String program, {required Set<String> roots}) {
  final Set<String> written = <String>{};
  for (final YamlMap step in _stepsIn(program)) {
    if (step['step'] != writeFileStep) {
      continue;
    }
    final Object? path = step['path'];
    if (path is! String) {
      continue;
    }
    for (final String root in roots) {
      if (path.startsWith('$root/')) {
        written.add(path.substring(root.length + 1));
        break;
      }
    }
  }
  return written;
}

/// Walks every document [yaml] holds, which is more than one where a file separates them with
/// `---` — the shape the project manifests have.
void _walkAll(String yaml, void Function(YamlMap) visit) {
  for (final YamlDocument document in loadYamlDocuments(yaml)) {
    _walk(document.contents, visit);
  }
}

void _walk(Object? node, void Function(YamlMap) visit) {
  if (node is YamlMap) {
    visit(node);
    for (final Object? key in node.keys) {
      _walk(node[key], visit);
    }
  } else if (node is YamlList) {
    for (final Object? each in node) {
      _walk(each, visit);
    }
  }
}

final RegExp _valuesRef = RegExp(r'^\$[A-Za-z_][A-Za-z0-9_-]*/');

/// A `$<ref>/` list entry read off the TEXT of a manifest, wherever the line stands in it.
///
/// Needed because four of this repository's value chains stand inside a `templatePatch:` block,
/// which is a literal block scalar — a string to YAML, and invisible to a walk of the parsed
/// document. Those blocks exist because a `{{- range }}` over a member's charts cannot be written in
/// the typed template without breaking a static parse, and a reader that walked only the parse would
/// see the generators of `argocd/apps/consumers-appset.yaml` and `argocd/apps/tenants-appset.yaml`
/// and not one of their value files.
final RegExp _refEntryLine = RegExp(
  r'^[ \t]*-[ \t]+(\$[A-Za-z_][A-Za-z0-9_-]*/.*)$',
  multiLine: true,
);

/// [raw] with its trailing comment and its surrounding quotes removed.
String _entry(String raw) {
  String scalar = raw.trim();
  final int comment = scalar.indexOf(' #');
  if (comment >= 0) {
    scalar = scalar.substring(0, comment).trim();
  }
  final bool quoted =
      scalar.length >= 2 &&
      ((scalar.startsWith('"') && scalar.endsWith('"')) ||
          (scalar.startsWith("'") && scalar.endsWith("'")));
  return quoted ? scalar.substring(1, scalar.length - 1) : scalar;
}

/// Every path of this repository [manifest] reads, as a `valueFiles` entry or a generator glob.
///
/// Collected from the whole of every document rather than from a fixed place in it, because a helm
/// block stands wherever a source needs one and a matrix generator nests its git generator one
/// level further down — and, for the `$<ref>/` entries, off the text as well, because a
/// `templatePatch:` block hides a whole values chain from any walk of the parse.
///
/// A `$<ref>/` prefix is dropped and what is left is taken as a path of this repository. A
/// chart-relative entry — one with no `$<ref>/` — is left out: it resolves against its own source's
/// chart directory, which is a place no deploy program writes into.
Set<String> appsetReadPathsIn(String manifest) {
  final Set<String> read = <String>{};
  _walkAll(manifest, (YamlMap node) {
    final Object? files = node['files'];
    if (files is YamlList) {
      for (final YamlMap entry in files.whereType<YamlMap>()) {
        final Object? path = entry['path'];
        if (path is String) {
          read.add(path);
        }
      }
    }
    final Object? valueFiles = node['valueFiles'];
    if (valueFiles is YamlList) {
      for (final Object? entry in valueFiles) {
        if (entry is String && _valuesRef.hasMatch(entry)) {
          read.add(entry.substring(entry.indexOf('/') + 1));
        }
      }
    }
  });
  for (final RegExpMatch found in _refEntryLine.allMatches(manifest)) {
    final String entry = _entry(found.group(1)!);
    if (_valuesRef.hasMatch(entry)) {
      read.add(entry.substring(entry.indexOf('/') + 1));
    }
  }
  return read;
}

// ── holding one against the other ───────────────────────────────────────────

/// A value this check cannot know: a program's slot, a stamp marker, a render-time action or a
/// generator's glob star. Each stands for any single path segment's worth of characters.
final RegExp _wildcard = RegExp(r'\{\{.*?\}\}|<[^<>/]*>|__[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*__|\*');

/// The character a wildcard is folded to before a shape is matched against it.
///
/// Any character no path carries would do; what matters is that a shape's own `[^/]*` accepts it,
/// so a written `clusters/active/<fqdn>.yaml` is answered by a read `clusters/active/*.yaml`
/// without either side having to know what the other's wildcard stands for. Not the empty
/// string, which would let a shape carrying no wildcard answer a path that does.
const String _folded = '\u0001';

String _literal(String path) => path.replaceAll(_wildcard, _folded);

RegExp _shape(String path) => RegExp(
  '^${path.splitMapJoin(_wildcard, onMatch: (Match each) => '[^/]*', onNonMatch: RegExp.escape)}\$',
);

/// Whether [read] answers [written], with every wildcard on either side standing for any single
/// segment's worth of characters.
bool readAnswersWritten(String read, String written) => _shape(read).hasMatch(_literal(written));

/// Every path of [written] that nothing in [read] answers.
///
/// [written] names, per program, the paths that program writes into a checkout of this repository;
/// [read] is every path the ApplicationSets of this repository load or select.
List<UnreadWrittenPath> auditWrittenPaths({
  required Map<String, Set<String>> written,
  required Set<String> read,
}) {
  final List<UnreadWrittenPath> found = <UnreadWrittenPath>[];
  for (final MapEntry<String, Set<String>> program in written.entries) {
    for (final String path in program.value) {
      if (read.any((String each) => readAnswersWritten(each, path))) {
        continue;
      }
      found.add(
        UnreadWrittenPath(
          where: program.key,
          path: path,
          because:
              'no ApplicationSet of this repository loads it as a values file or selects it with a '
              'generator. A rendered file nothing loads costs more than a missing one: the run '
              'writes it, the commit carries it, every step reports green, and the values it holds '
              'are absent from every Application on the cluster with nothing anywhere saying so.',
        ),
      );
    }
  }
  return found;
}
