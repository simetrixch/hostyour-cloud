/// named-paths — every path of this repository that a file of this repository names is one the
/// repository carries, or one `branch-classes.yaml` declares it deliberately does not.
///
/// **THE DEFECT THIS EXISTS FOR, MEASURED.** A comment that names a file is the only map most of
/// this tree has: a values file says which generator loads it, a chart says which manifest gates it,
/// a template says which books branch its registrations stand on. When the thing moves and the
/// sentence does not, the sentence keeps reading as an instruction and every side reports success —
/// nothing renders a comment, so nothing fails. Two families were standing in this tree when this
/// check was written, both found by hand rather than by anything running:
///
///   * `installation/apps/<app>.yaml`, named in eleven places as the per-branch deploy toggle whose
///     `deploy:` line decides where an app runs. There is no such file and no writer of one: what
///     decides it is `apps/<app>/app.yaml`'s `runsOn:` on the trunk, selected by the app generator
///     against the role stamped over `__CLUSTER_ROLE__`.
///   * `argocd/<stage>/apps/*.yaml`, named in twenty-five places. The three per-stage argocd trees
///     became ONE parameterized tree at `argocd/apps/`, and one of the twenty-five was not a comment
///     at all — `apps/consumer-build/templates/pipeline-release.yaml` walked
///     `argocd/${STAGE}/apps/*.yaml` to derive which tenants a release reaches, the glob matched
///     nothing, the loop's own `[ -f ]` guard stepped over it, and the reach came out EMPTY with the
///     pipeline green. That glob has since been repointed and the derivation fills the stage itself;
///     what stands here is the shape the defect had, because it is the founding case of this check
///     and the one the counter-probe is written against.
///
/// **BOTH SIDES ARE READ WHERE THEY ARE DECIDED.** What the repository carries is `git ls-files` —
/// the tree a cluster clones, so an untracked file on somebody's disk is not an answer. What it
/// deliberately does not carry is `branch-classes.yaml`'s `trunk-absent:` and `outside:` sections,
/// which exist to say exactly that: the first for a path that stands on an install branch or on the
/// books branch, the second for a path held outside git on purpose. Neither list is restated here.
/// Nothing read either section until this check: the sibling `appset-read-paths` reads that file,
/// but only its `classes:` section, and what still holds the two stamping routines the file was
/// written for to any of it is what its own header says — nothing. So a `trunk-absent:` row and the
/// tree's behaviour were two statements with nothing between them.
///
/// **WHAT COUNTS AS NAMING A PATH.** A run of at least two `/`-joined segments ending in one of
/// [namedPathSuffixes], whose FIRST segment is a top-level directory this repository tracks. The
/// first-segment test is what keeps the other trees out: `hostyour-manager/shared/branches.ts` and
/// `ansiwise/programs/deploy-branch.yaml` are named all over this tree and are no business of this
/// check, and they fall out on their own rather than through a list of foreign names kept here.
///
/// **A MARKER IS A WILDCARD, ON BOTH SIDES.** `<fqdn>`, `<stage>`, `{{ .name }}`, `__STAGE__` and a
/// bare `*` all stand for a value neither side can know, and they appear on either side of the same
/// comparison — a comment says `clusters/active/<fqdn>.yaml` and `trunk-absent:` says
/// `clusters/active/*.yaml`. So a named path is answered when it and the answer can denote one
/// path, which is asked in both directions: the named path's wildcards against the answer's text,
/// and the answer's wildcards against the named path's text.
///
/// **WHAT IT IS NOT.** `chart-paths` beside it resolves the paths the chart MATERIAL names — a
/// `file://` dependency, a `valueFiles` entry, a generator glob, a source `path:` — each read off
/// the field it stands in and judged by the rule that field obeys. This one reads the tracked files
/// as TEXT and judges what they NAME in prose, which is the half no field carries and no render
/// touches. The two overlap on nothing: a path in a `valueFiles` list is answered there by the rule
/// for value files, and a path in the paragraph above it is answered here.
///
/// **WHAT IT DOES NOT REACH.** It judges the NAME and never the sentence around it. A comment
/// pointing at a file that exists and says the opposite of what the comment claims passes here, and
/// so does a line anchor: `pipeline-release.yaml:806-810` resolves to the file, and whether line 806
/// is still what it was is not readable from a path.
///
/// Three shapes of name fall outside [_candidate] altogether, and a reader has to know them because
/// both families above are written in one of them somewhere in this tree. A path named as a
/// DIRECTORY — a run of segments ending in `/`, with no filename after it — never matches, so
/// `installation/apps/` at `branch-classes.yaml:224` and `:310` is invisible here, and so was the
/// twenty-fifth `argocd/__STAGE__/apps/` in `argocd/apps/projects.yaml`: it walked past this check
/// and was found by a person reading the file, as the other twenty-four had been. A `"` ends a run,
/// because it is outside the character class, so a glob written as
/// `"${WORK}"/hostyour-cloud/argocd/"${STAGE}"/apps/*.yaml` restarts after the quote at a first
/// segment this repository does not track and is dropped; the founding defect of this check is a
/// shape the check cannot read. That one has been repaired in the pipeline since — the line is
/// quoted here for its SHAPE and no longer stands anywhere in the tree, so no line number is given
/// for it. And a root-level file name carries no `/` at all, so a sentence
/// naming `branch-classes.yml` where the tree carries `branch-classes.yaml` is not held either.
/// All three were planted into the real tree and the suite stayed green. Widening [_candidate] to
/// take a trailing-slash directory reference is the first of the three worth doing, and it is not
/// done here.
///
/// It judges the name of a path of THIS repository only. A mechanism named in prose with no path —
/// a `StampRole` that prunes an install branch, a guard nobody built — is exactly the same defect
/// and is not held here at all; that is hostyour-cloud#69 and hostyour-cloud#60, both found by a
/// person reading the file.
///
/// The first-segment test is a heuristic and it cuts the wrong way when another tree carries a
/// top-level directory of the same name. The tenant catalog has a `charts/` as this repository does,
/// so `charts/<chart>/pins-<stage>.yaml` — a path OF THE CATALOG — reads here as one of ours and is
/// reported. Three such lines were standing when this was written and all three were rewritten to
/// say what they are ("the catalog's per-chart `pins-<stage>.yaml`"), which is what a reader needed
/// anyway; a fourth would be reported the same way, and the answer is to name the tree, not to
/// widen this check.
///
/// It reads the tracked tree as TEXT, not as comments: a path named in a manifest's own body counts
/// the same as one named in a comment. That is deliberate — the dead glob above was in a shell
/// script, not in a comment — but it means a value that merely looks like a path is judged as one.
///
/// A path carrying a wildcard is answered by ANY tracked path it could denote, so
/// `apps/*/values-dev.yaml` is answered while `apps/nonexistent/values-dev.yaml` is not: a wildcard
/// is a statement about a family, and a family with one member standing is a family that exists.
///
/// `checks/` is not read, and that is the hole a reader has to know about: the suite beside this
/// library plants paths that do not exist in order to see this check go red, so a path named in a
/// check's own doc comment is judged by nothing.
library;

/// The file suffixes a named path may end in.
///
/// The suffixes this tree's own material carries, and the reason the list is closed rather than
/// "anything after a dot": a dotted word is not rare in a comment — a domain, a version, a package —
/// and a reader that took every one of them would report `example.invalid` and `v0.92.0` as missing
/// files.
const List<String> namedPathSuffixes = <String>[
  'yaml',
  'yml',
  'dart',
  'sh',
  'ps1',
  'tpl',
  'ts',
  'json',
  'lock',
  'md',
  'toml',
];

/// One path a file of this repository names that the repository neither carries nor declares absent.
final class UnansweredPath {
  /// Records that [where] names [path], which resolves to nothing, [because].
  const UnansweredPath({required this.where, required this.path, required this.because});

  /// The file somebody has to open, as the tree names it.
  final String where;

  /// The path it names, exactly as written.
  final String path;

  /// What is wrong with it, in the words whoever wrote it reads.
  final String because;

  /// The one line a refusal says about it.
  @override
  String toString() => '$where names $path — $because';
}

/// The character a wildcard and a marker are both folded to before either side is compared.
///
/// One character, so that a pattern's own `*` and a comment's `<fqdn>` become the same thing and the
/// comparison below has one shape instead of two.
const String _wildcard = '*';

final RegExp _marker = RegExp(
  r'<[^/<>]*>|\{\{[^/{}]*\}\}|\{[^/{}]*\}|__[A-Z0-9_]+__|\$\{[^/{}]*\}',
);

final RegExp _candidate = RegExp(
  r'(?:[A-Za-z0-9_.*<>{}$-]+/)+[A-Za-z0-9_.*<>{}$-]+\.([A-Za-z0-9]+)',
);

/// [path] with every marker folded to [_wildcard].
String _folded(String path) => path.replaceAll(_marker, _wildcard);

/// Whether [pattern] — a path with [_wildcard] in it — denotes [text].
///
/// A `*` crosses `/`, which is the sense `branch-classes.yaml` states for its own patterns and the
/// sense a shell glob gives one: `apps/*` is the whole subtree, not its first level.
bool _denotes(String pattern, String text) {
  final String expression = pattern.split(_wildcard).map(RegExp.escape).join('.*');
  return RegExp('^$expression\$').hasMatch(text);
}

/// Whether [named] and [answer] can denote one path, asked in both directions.
///
/// Both directions, because either side may be the one carrying the wildcard: a comment naming
/// `installation/values/<app>.yaml` is answered by the literal row `installation/values/manager.yaml`
/// through the first direction, and a comment naming `apps/*/Chart.lock` is answered by the pattern
/// row of the same text through the second.
bool _sameFamily(String named, String answer) {
  final String namedText = named.replaceAll(_wildcard, '');
  final String answerText = answer.replaceAll(_wildcard, '');
  return _denotes(named, answerText) || _denotes(answer, namedText);
}

/// Every path of this repository [text] names, given the [topLevelDirectories] it tracks.
///
/// The first segment decides: a run of segments starting at a directory this repository carries is a
/// path OF this repository, and one starting anywhere else belongs to another tree and is not this
/// check's business.
Set<String> namedPathsIn(String text, {required Set<String> topLevelDirectories}) {
  final Set<String> named = <String>{};
  for (final RegExpMatch found in _candidate.allMatches(text)) {
    final String path = found.group(0)!;
    if (!namedPathSuffixes.contains(found.group(1))) {
      continue;
    }
    if (!topLevelDirectories.contains(path.split('/').first)) {
      continue;
    }
    named.add(path);
  }
  return named;
}

/// The patterns [branchClasses] declares this repository deliberately does not track.
///
/// Read off the section headers rather than the parsed document, so a section that stops being a
/// map — a conflict marker in it, a row commented out — answers nothing instead of answering
/// silently with less.
Set<String> declaredAbsentIn(String branchClasses, {required List<String> sections}) {
  final Set<String> declared = <String>{};
  String? inside;
  for (final String line in branchClasses.split('\n')) {
    final String content = line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
    if (content.isEmpty || content.startsWith('#')) {
      continue;
    }
    if (!content.startsWith(' ')) {
      inside = content.endsWith(':') ? content.substring(0, content.length - 1) : null;
      continue;
    }
    if (inside == null || !sections.contains(inside)) {
      continue;
    }
    final RegExpMatch? row = RegExp(r'^\s+"([^"]+)"\s*:').firstMatch(content);
    if (row != null) {
      declared.add(row.group(1)!);
    }
  }
  return declared;
}

/// Every path in [named] that neither [tracked] nor [declaredAbsent] answers.
///
/// [named] is keyed by the file the path stands in, so a report names the place to go rather than
/// only the path that is wrong.
List<UnansweredPath> auditNamedPaths({
  required Map<String, Set<String>> named,
  required Set<String> tracked,
  required Set<String> declaredAbsent,
}) {
  final List<UnansweredPath> unresolved = <UnansweredPath>[];
  for (final MapEntry<String, Set<String>> each in named.entries) {
    for (final String path in each.value.toList()..sort()) {
      final String folded = _folded(path);
      if (tracked.any((String carried) => _denotes(folded, carried))) {
        continue;
      }
      if (declaredAbsent.any((String pattern) => _sameFamily(folded, pattern))) {
        continue;
      }
      unresolved.add(
        UnansweredPath(
          where: each.key,
          path: path,
          because:
              'this repository carries no such path and branch-classes.yaml declares none of that '
              'family absent — either the file moved and this line did not, or the line is naming '
              'a mechanism nobody built',
        ),
      );
    }
  }
  return unresolved;
}
