/// chart-paths — every path the chart material names resolves in the TRACKED tree.
///
/// **Where an unresolved path surfaces, which is why this is checked at all.** A cluster reads this
/// repository from a fresh clone, so what exists there is what `git ls-files` says — not what this
/// machine's file system answers. A `file://` dependency spelled `charts/Common` resolves on a
/// case-insensitive checkout and fails on the cluster; a `valueFiles` entry that nothing carries
/// either fails the sync or, under `ignoreMissingValueFiles`, lets the Application render from
/// whatever files are left, with no error anywhere. Both defects are committed here and surface
/// there, so the only thing that can find them is something that reads these files against the
/// tracked paths.
///
/// **What "names a path" means is decided per kind, and that decision is the check:**
///
/// - A Helm dependency `repository: file://<dir>` names a DIRECTORY, and what must exist is a
///   tracked `Chart.yaml` inside it whose `name` answers the dependency's — both are what
///   `helm dependency build` requires before it vendors anything.
/// - A valueFile is judged only where it stands in THIS repository: a `$<ref>/` path against the
///   source carrying that `ref`, a bare path against its own source's `path`. A file in another
///   repository is not this tree's to answer, and a path composed at render time (`{{ ... }}`)
///   cannot be resolved by reading files — both are left alone rather than guessed at.
/// - A git generator's `files: - path:` is a GLOB, and what must exist is at least one tracked file
///   matching it. A generator that matches nothing produces zero Applications and reports no error
///   at all — the reconcile succeeds and the cluster is empty.
/// - A source's `path:` is a DIRECTORY, and what must exist is at least one tracked file inside it.
///   ArgoCD renders an absent directory as an empty manifest set, so the Application syncs green
///   with nothing in it.
/// - A stamp marker (`__STAGE__`, `__CLUSTER__`, ...) is a value this check cannot know, so it
///   stands as a wildcard: the path resolves when ANY tracked file matches the shape.
///
/// **What this tree can answer for a generator, and what it cannot.** A generator names a repository
/// and a revision. Where either is another repository's, or a revision this tree is not — every
/// `revision: __BOOKS_BRANCH__`, which reads the books branch — the files it selects are not tracked
/// on master and their absence here says nothing. Those generators are left alone, so
/// `argocd/apps/slaves-appset.yaml`'s `clusters/active/*.yaml` and the two
/// `registrations/*/__STAGE__.yaml` generators are NOT covered by this check and moving what they
/// select is not caught by anything.
///
/// **What `ignoreMissingValueFiles` makes deliberate — and what it cannot.** The flag exists for
/// files whose presence this repository does not control: a chart-relative overlay another
/// repository carries, a pin a later writer commits, a path a render composes. Absence of those is
/// a design, and reporting it would be noise. A static `$<ref>/` path INTO this repository is the
/// opposite case: this tree is the only place it could ever exist, so under the flag its absence
/// is not a deliberate design but a file that can never load — the platform values it was meant to
/// bring are silently missing from every render. That distinction is the audit
/// `argocd/apps/tenants-appset.yaml`'s own comment names as lost; this restores it.
library;

import 'package:yaml/yaml.dart';

/// A path the chart material names and the tracked tree does not answer.
final class UnresolvedPath {
  /// Records that [origin] names [named] and the tree does not answer it, for [reason].
  const UnresolvedPath(this.origin, this.named, this.reason);

  /// The file that names the path, relative to the repository.
  final String origin;

  /// The path exactly as the file spells it.
  final String named;

  /// What must exist and does not, said so the finding can be acted on.
  final String reason;

  /// The one line a refusal says about it.
  @override
  String toString() => '$origin names $named — $reason';
}

/// The `owner/name` a git URL points at, so two spellings of one repository compare equal.
///
/// `https://github.com/x/y.git`, `git@github.com:x/y.git` and `ssh://git@github.com/x/y` all name
/// the same repository; what identifies it is the last two path segments with the `.git` suffix
/// dropped. A URL that carries a stamp marker or a template keeps its own shape and therefore
/// never equals a real repository — which is the point: what cannot be identified is not judged.
String repositorySlug(String url) {
  String slug = url.trim().toLowerCase();
  slug = slug.replaceFirst(RegExp(r'^(https?|ssh|git)://'), '');
  slug = slug.replaceFirst(RegExp(r'^git@'), '').replaceFirst(':', '/');
  if (slug.endsWith('.git')) {
    slug = slug.substring(0, slug.length - '.git'.length);
  }
  final List<String> segments = slug.split('/').where((String each) => each.isNotEmpty).toList();
  return segments.length >= 2 ? segments.sublist(segments.length - 2).join('/') : slug;
}

/// A stamp marker: a value the branch programs write and this check cannot know, so it matches any
/// single path segment's worth of characters.
final RegExp _marker = RegExp(r'__[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*__');

/// Whether [tracked] answers [target], with every stamp marker standing as a wildcard.
bool _resolves(String target, Set<String> tracked) {
  if (!_marker.hasMatch(target)) {
    return tracked.contains(target);
  }
  final String pattern = target.splitMapJoin(
    _marker,
    onMatch: (Match each) => '[^/]*',
    onNonMatch: RegExp.escape,
  );
  final RegExp shape = RegExp('^$pattern\$');
  return tracked.any(shape.hasMatch);
}

/// [relative] joined onto [base] with `.` and `..` folded away, or null where it climbs out of the
/// tree — a place no clone can carry.
String? _normalize(String base, String relative) {
  final List<String> kept = <String>[];
  for (final String segment in <String>[...base.split('/'), ...relative.split('/')]) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    if (segment == '..') {
      if (kept.isEmpty) {
        return null;
      }
      kept.removeLast();
    } else {
      kept.add(segment);
    }
  }
  return kept.join('/');
}

/// Every `file://` dependency of [charts] that no tracked chart answers.
///
/// [charts] is the content of every tracked `Chart.yaml` by the path it stands at — ALL of them,
/// because the target of one dependency is the source of the next judgement: a dependency resolves
/// when `<dir>/Chart.yaml` is in [tracked] AND the `name:` it carries matches the dependency's,
/// since helm locates a vendored chart by that name and refuses a mismatch. [tracked] comes from
/// `git ls-files`, never from the file system: the file system of this machine answers spellings
/// and uncommitted files a fresh clone does not have.
List<UnresolvedPath> auditChartDependencies({
  required Map<String, String> charts,
  required Set<String> tracked,
}) {
  final List<UnresolvedPath> found = <UnresolvedPath>[];
  final List<String> origins = charts.keys.toList()..sort();
  for (final String origin in origins) {
    final Object? parsed = loadYaml(charts[origin]!);
    if (parsed is! Map) {
      continue;
    }
    final Object? dependencies = parsed['dependencies'];
    if (dependencies is! List) {
      continue;
    }
    final String base = origin.contains('/') ? origin.substring(0, origin.lastIndexOf('/')) : '';
    for (final Object? dependency in dependencies) {
      if (dependency is! Map) {
        continue;
      }
      final Object? repository = dependency['repository'];
      final Object? name = dependency['name'];
      if (repository is! String || !repository.startsWith('file://')) {
        continue;
      }
      final String relative = repository.substring('file://'.length);
      final String? directory = relative.startsWith('/') ? null : _normalize(base, relative);
      if (directory == null) {
        found.add(
          UnresolvedPath(
            origin,
            repository,
            'the dependency reaches outside the tree, a place no clone carries',
          ),
        );
        continue;
      }
      final String target = '$directory/Chart.yaml';
      if (!tracked.contains(target)) {
        found.add(
          UnresolvedPath(
            origin,
            repository,
            'no tracked $target answers it, so helm dependency build fails on a fresh clone '
            'even where this machine\'s file system resolves the spelling',
          ),
        );
        continue;
      }
      final Object? targetParsed = charts.containsKey(target) ? loadYaml(charts[target]!) : null;
      final Object? targetName = targetParsed is Map ? targetParsed['name'] : null;
      if (name is String && targetName is String && name != targetName) {
        found.add(
          UnresolvedPath(
            origin,
            repository,
            'the chart there is named "$targetName", not "$name" — helm locates a vendored '
            'dependency by name and refuses the mismatch',
          ),
        );
      }
    }
  }
  return found;
}

/// Every `valueFiles` entry of [manifests] that must resolve in this tree and does not.
///
/// [manifests] is the raw text of the ArgoCD material by the path it stands at — raw because
/// `templatePatch` blocks carry go-template control lines no YAML parser accepts, so the lists are
/// read by shape instead. [repository] is the `owner/name` of the tree under audit (from its own
/// remote, so no name is written here); it decides which sources' files this tree can answer at
/// all. What is judged and what is left alone is the contract the library comment states.
List<UnresolvedPath> auditValueFiles({
  required Map<String, String> manifests,
  required Set<String> tracked,
  required String repository,
}) {
  final List<UnresolvedPath> found = <UnresolvedPath>[];
  final List<String> origins = manifests.keys.toList()..sort();
  for (final String origin in origins) {
    _scanManifest(origin, manifests[origin]!, tracked, repository, found);
  }
  return found;
}

/// A scalar with its trailing comment and its surrounding quotes removed.
String _plain(String raw) {
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

/// The leading spaces of [line], which is what carries structure once YAML cannot be parsed.
int _indent(String line) => line.length - line.trimLeft().length;

/// An anchor definition `&name value`, wherever it stands on a line.
final RegExp _anchor = RegExp(r'&([A-Za-z0-9_-]+)\s+(.+)$');

/// A source item's opening line. Only spec sources open with `- repoURL:`; a git generator's
/// `repoURL:` carries no dash, which is what keeps generators out of this scan.
final RegExp _source = RegExp(r'^\s*-\s+repoURL:\s*(.+)$');

/// Every `&name value` of [lines], so an alias further down answers what the anchor holds.
Map<String, String> _anchorsIn(List<String> lines) {
  final Map<String, String> anchors = <String, String>{};
  for (final String line in lines) {
    final RegExpMatch? match = _anchor.firstMatch(line);
    if (match != null) {
      anchors[match.group(1)!] = _plain(match.group(2)!);
    }
  }
  return anchors;
}

/// [raw] with its alias or its own anchor resolved, so `*repo` and `&repo "url"` both answer the URL.
String _valueOf(String raw, Map<String, String> anchors) {
  final String plain = _plain(raw);
  if (plain.startsWith('*')) {
    return anchors[plain.substring(1)] ?? plain;
  }
  final RegExpMatch? definition = _anchor.firstMatch(plain);
  return definition != null ? _plain(definition.group(2)!) : plain;
}

/// Reads every `valueFiles:` list of [text] by shape and appends what does not resolve to [found].
void _scanManifest(
  String origin,
  String text,
  Set<String> tracked,
  String repository,
  List<UnresolvedPath> found,
) {
  final List<String> lines = text.split('\n');

  final Map<String, String> anchors = _anchorsIn(lines);
  String value(String raw) => _valueOf(raw, anchors);

  // Which repository each `ref:` name stands for — what `$<ref>/` paths resolve against.
  final Map<String, String> refs = <String, String>{};
  final RegExp refLine = RegExp(r'^\s*ref:\s*(\S+)');
  for (int i = 0; i < lines.length; i++) {
    final RegExpMatch? ref = refLine.firstMatch(lines[i]);
    if (ref == null) {
      continue;
    }
    for (int j = i - 1; j >= 0; j--) {
      final RegExpMatch? source = _source.firstMatch(lines[j]);
      if (source != null) {
        refs[_plain(ref.group(1)!)] = value(source.group(1)!);
        break;
      }
    }
  }

  for (int i = 0; i < lines.length; i++) {
    if (lines[i].trim() != 'valueFiles:') {
      continue;
    }
    final int listIndent = _indent(lines[i]);

    // The enclosing helm block: the nearest real line above at lower indent must be `helm:`,
    // because valueFiles is helm's direct child.
    int helmLine = -1;
    for (int j = i - 1; j >= 0; j--) {
      final String trimmed = lines[j].trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }
      if (_indent(lines[j]) < listIndent) {
        if (trimmed == 'helm:') {
          helmLine = j;
        }
        break;
      }
    }
    if (helmLine < 0) {
      continue;
    }
    final int helmIndent = _indent(lines[helmLine]);

    // Whether this helm block declares absence deliberate, read among its direct children.
    bool ignoreMissing = false;
    for (int j = helmLine + 1; j < lines.length; j++) {
      final String trimmed = lines[j].trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }
      if (_indent(lines[j]) <= helmIndent) {
        break;
      }
      if (_indent(lines[j]) == listIndent &&
          RegExp(r'^ignoreMissingValueFiles:\s*true\b').hasMatch(trimmed)) {
        ignoreMissing = true;
        break;
      }
    }

    // The source the helm block belongs to: its repository and its chart path, which is what the
    // list's bare entries resolve against.
    String? repoUrl;
    int sourceLine = -1;
    for (int j = helmLine - 1; j >= 0; j--) {
      final RegExpMatch? source = _source.firstMatch(lines[j]);
      if (source != null) {
        repoUrl = value(source.group(1)!);
        sourceLine = j;
        break;
      }
    }
    String? chartPath;
    if (sourceLine >= 0) {
      for (int j = sourceLine; j < helmLine; j++) {
        final RegExpMatch? path = RegExp(r'^\s*path:\s*(.+)$').firstMatch(lines[j]);
        if (path != null) {
          chartPath = _plain(path.group(1)!);
          break;
        }
      }
    }

    for (int j = i + 1; j < lines.length; j++) {
      final String trimmed = lines[j].trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }
      if (_indent(lines[j]) <= listIndent) {
        break;
      }
      if (trimmed.startsWith('{{')) {
        continue; // a template control line between entries, not an entry
      }
      if (!trimmed.startsWith('- ')) {
        break;
      }
      final String entry = _plain(trimmed.substring(2));
      if (entry.contains('{{')) {
        continue; // composed at render time — not resolvable by reading files
      }

      String? target;
      bool anchoredHere = false;
      if (entry.startsWith(r'$')) {
        final int slash = entry.indexOf('/');
        final String refName = slash < 0 ? entry.substring(1) : entry.substring(1, slash);
        final String? refRepo = refs[refName];
        if (refRepo == null) {
          found.add(
            UnresolvedPath(
              origin,
              entry,
              'no source in this file carries ref: $refName, so the reference resolves nowhere — '
              'ignoreMissingValueFiles forgives a missing file, never a missing source',
            ),
          );
          continue;
        }
        if (repositorySlug(refRepo) != repository || slash < 0) {
          continue; // another repository's file is not this tree's to answer
        }
        target = _normalize('', entry.substring(slash + 1));
        anchoredHere = true;
      } else {
        if (repoUrl == null || repositorySlug(repoUrl) != repository) {
          continue; // another repository's file is not this tree's to answer
        }
        if (chartPath == null || chartPath.contains('{{')) {
          continue; // the base itself is composed at render time
        }
        target = _normalize(chartPath, entry);
      }
      if (target == null) {
        found.add(
          UnresolvedPath(
            origin,
            entry,
            'the path reaches outside the tree, a place no clone carries',
          ),
        );
        continue;
      }
      if (_resolves(target, tracked)) {
        continue;
      }
      if (!ignoreMissing) {
        found.add(
          UnresolvedPath(
            origin,
            entry,
            'no tracked $target answers it and nothing declares its absence deliberate — the '
            'Application errors instead of rendering',
          ),
        );
      } else if (anchoredHere) {
        found.add(
          UnresolvedPath(
            origin,
            entry,
            'no tracked $target answers it, and ignoreMissingValueFiles cannot make that '
            'deliberate: the flag speaks for files this repository does not control, but this '
            'tree is the only place a \$-ref path into it could ever exist — the file can never '
            'load, so every render silently goes without the values it names',
          ),
        );
      }
    }
  }
}

/// Every git generator `files: - path:` glob of [manifests] that this tree must answer and does not.
///
/// [manifests] is the raw text of the ArgoCD material by the path it stands at, read by shape for
/// the same reason [auditValueFiles] reads it that way. [repository] is the `owner/name` of the tree
/// under audit.
///
/// **What a glob matching nothing costs.** The ApplicationSet controller treats a git generator that
/// selects no file as a generator with no parameters: it produces zero Applications, records no
/// condition and reports success. Whatever those Applications were is simply not on the cluster, and
/// nothing anywhere says so — which is why a moved path has to be caught in this tree.
///
/// **Which generators this tree can answer.** Only one that reads THIS repository at a revision this
/// check can hold against the tracked tree. A `repoURL` of another repository, and a `revision`
/// carrying a stamp marker or a template, both name material that is not tracked here; their globs
/// are left alone rather than reported, and the library comment names the three that fall out that
/// way.
List<UnresolvedPath> auditGeneratorFiles({
  required Map<String, String> manifests,
  required Set<String> tracked,
  required String repository,
}) {
  final List<UnresolvedPath> found = <UnresolvedPath>[];
  for (final String origin in manifests.keys.toList()..sort()) {
    final List<String> lines = manifests[origin]!.split('\n');
    final Map<String, String> anchors = _anchorsIn(lines);
    for (int i = 0; i < lines.length; i++) {
      if (lines[i].trim() != 'files:') {
        continue;
      }
      final int listIndent = _indent(lines[i]);
      final String? repoUrl = _siblingScalar(lines, i, listIndent, 'repoURL', anchors);
      final String? revision = _siblingScalar(lines, i, listIndent, 'revision', anchors);
      if (repoUrl == null || repositorySlug(repoUrl) != repository) {
        continue; // another repository's files are not this tree's to answer
      }
      if (revision == null || _marker.hasMatch(revision) || revision.contains('{{')) {
        continue; // another branch's files are not this tree's to answer either
      }
      for (final String glob in _listEntries(lines, i, listIndent, 'path')) {
        if (glob.contains('{{')) {
          continue; // composed at render time — not resolvable by reading files
        }
        if (_matchesAny(glob, tracked)) {
          continue;
        }
        found.add(
          UnresolvedPath(
            origin,
            glob,
            'no tracked file matches it on $revision, so the generator selects nothing — an '
            'ApplicationSet whose generator finds nothing produces zero Applications and reports '
            'no error at all',
          ),
        );
      }
    }
  }
  return found;
}

/// Every source `path:` of [manifests] that names a directory of this repository and finds none.
///
/// The same three arguments and the same contract as [auditGeneratorFiles]: a source pointing at
/// another repository, or at a revision carrying a stamp marker, names material this tree cannot
/// answer, and a `path` composed at render time cannot be resolved by reading files.
///
/// **What an absent directory costs.** ArgoCD renders a source whose `path` holds nothing as an
/// empty manifest set. The Application is created, syncs, and reports Healthy and Synced with no
/// resource in it — the same silence a generator matching nothing gives, one level down.
List<UnresolvedPath> auditSourcePaths({
  required Map<String, String> manifests,
  required Set<String> tracked,
  required String repository,
}) {
  final List<UnresolvedPath> found = <UnresolvedPath>[];
  final RegExp opening = RegExp(r'^(\s*)(-\s+)?repoURL:\s*(.+)$');
  for (final String origin in manifests.keys.toList()..sort()) {
    final List<String> lines = manifests[origin]!.split('\n');
    final Map<String, String> anchors = _anchorsIn(lines);
    for (int i = 0; i < lines.length; i++) {
      final RegExpMatch? source = opening.firstMatch(lines[i]);
      if (source == null) {
        continue;
      }
      final int keyIndent = source.group(1)!.length + (source.group(2)?.length ?? 0);
      final String repoUrl = _valueOf(source.group(3)!, anchors);
      final String? path = _siblingScalar(lines, i, keyIndent, 'path', anchors);
      if (path == null) {
        continue; // a values-only source names no directory at all
      }
      final String? revision =
          _siblingScalar(lines, i, keyIndent, 'targetRevision', anchors) ??
          _siblingScalar(lines, i, keyIndent, 'revision', anchors);
      if (repositorySlug(repoUrl) != repository) {
        continue; // another repository's directory is not this tree's to answer
      }
      if (revision == null || _marker.hasMatch(revision) || revision.contains('{{')) {
        continue; // another branch's directory is not this tree's to answer either
      }
      if (path.contains('{{')) {
        continue; // composed at render time — not resolvable by reading files
      }
      if (_matchesAny('$path/**', tracked)) {
        continue;
      }
      found.add(
        UnresolvedPath(
          origin,
          path,
          'no tracked file stands under it on $revision, so the source renders an empty manifest '
          'set — the Application is created and reports Synced with nothing in it',
        ),
      );
    }
  }
  return found;
}

/// The scalar under [key] among the direct children of the block the line at [line] belongs to.
///
/// [keyIndent] is the indentation the block's own keys stand at, so the search reads exactly the
/// siblings of that line and stops where the block does — at the first line indented less than they
/// are, which is either the parent's next key or the next item of the list this one is in. Both
/// directions are walked because a source states its `repoURL` before its `path` and a generator
/// states its `files` before neither, after both, or in between.
String? _siblingScalar(
  List<String> lines,
  int line,
  int keyIndent,
  String key,
  Map<String, String> anchors,
) {
  final RegExp wanted = RegExp('^$key:\\s*(.+)\$');
  for (final int direction in <int>[1, -1]) {
    for (int j = line + direction; j >= 0 && j < lines.length; j += direction) {
      final String trimmed = lines[j].trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        continue;
      }
      if (_indent(lines[j]) < keyIndent) {
        break;
      }
      if (_indent(lines[j]) != keyIndent) {
        continue;
      }
      final RegExpMatch? match = wanted.firstMatch(trimmed);
      if (match != null) {
        return _valueOf(match.group(1)!, anchors);
      }
    }
  }
  return null;
}

/// Every `- <key>: <scalar>` of the list opened at [line], whose entries stand deeper than
/// [listIndent].
List<String> _listEntries(List<String> lines, int line, int listIndent, String key) {
  final List<String> entries = <String>[];
  final RegExp wanted = RegExp('^-\\s+$key:\\s*(.+)\$');
  for (int j = line + 1; j < lines.length; j++) {
    final String trimmed = lines[j].trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      continue;
    }
    if (_indent(lines[j]) <= listIndent) {
      break;
    }
    final RegExpMatch? match = wanted.firstMatch(trimmed);
    if (match == null) {
      break;
    }
    entries.add(_plain(match.group(1)!));
  }
  return entries;
}

/// Whether any path in [tracked] matches [glob], with `*` stopping at a `/`, `**` crossing them and
/// every stamp marker standing as a wildcard the way [_resolves] lets it.
bool _matchesAny(String glob, Set<String> tracked) {
  final StringBuffer pattern = StringBuffer();
  int at = 0;
  while (at < glob.length) {
    final Match? marker = _marker.matchAsPrefix(glob, at);
    if (marker != null) {
      pattern.write('[^/]*');
      at = marker.end;
      continue;
    }
    final String character = glob[at];
    if (character == '*') {
      if (at + 1 < glob.length && glob[at + 1] == '*') {
        pattern.write('.*');
        at += 2;
        continue;
      }
      pattern.write('[^/]*');
      at += 1;
      continue;
    }
    if (character == '?') {
      pattern.write('[^/]');
      at += 1;
      continue;
    }
    pattern.write(RegExp.escape(character));
    at += 1;
  }
  final RegExp shape = RegExp('^$pattern\$');
  return tracked.any(shape.hasMatch);
}
