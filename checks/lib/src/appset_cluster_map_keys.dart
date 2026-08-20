/// What an ApplicationSet reads out of a cluster map, held against what the map's writers write.
///
/// **WHY THIS IS DANGEROUS AND NOT MERELY UNTIDY.** `clusters/active/<fqdn>.yaml` is one file read
/// across three repositories. This repository's generators SELECT maps by their fields and READ
/// fields out of the ones they matched; the deploy programs write a master's map from a
/// template; the Controller writes a slave's. Neither half fails loudly when the two drift apart:
///
///   * **a selector that matches nothing produces zero Applications and reports no error.** The
///     cluster runs, ArgoCD shows green, and the management plane of every slave is simply absent.
///   * **a template key no matched map carries ends the WHOLE reconcile** under
///     `goTemplateOptions: [missingkey=error]`, so not one Application of that set is created.
///
/// Both are invisible until somebody counts what should have been deployed, which is why something
/// has to read these files at the moment they are committed.
///
/// **NOTHING HERE RESTATES A KEY OR A VALUE.** A list of map keys written into this check would be
/// a fourth spelling of the same file, and the drift it watches for could then happen inside the
/// guard. Every side is read where it is decided:
///
///   * the keys a map may carry — [clusterMapTemplateKeysIn] over the deploy programs' map
///     template, and [clusterMapSchemaKeysIn] over the Controller's strict schema, which is the
///     writer of every map a `role: slave` selector can ever match;
///   * where a map's key gets its value — [clusterMapValueSourcesIn], out of the program row that
///     renders the map, as the name of the answer behind each key;
///   * where a selector's value gets its own — [stampedMarkersIn], out of the program rows that
///     stamp the generator tree, again as the name of an answer;
///   * which literals an answer may hold — [allowedAnswerValuesIn], out of the answer's own
///     `allowed:` list.
///
/// **THE RULE FOR A SELECTOR VALUE, which is the part that is easy to get wrong.** A map's key
/// holds whatever an ANSWER says, and an answer is one installation's own value — so a literal
/// written into a file that ships to every installation can only match where the answer itself is
/// closed to a list of words. Everything else must be a marker a branch program stamps, and it must
/// be stamped FROM THE SAME ANSWER the map's key is written from. Two answers that happen to agree
/// on one installation are not one answer: the moment an operator answers them differently the
/// selector matches nothing, and nothing goes red.
library;

import 'package:yaml/yaml.dart';

/// Where the deploy programs' cluster map template stands inside an installation tree.
const String installationClusterMapTemplate = 'ansiwise/templates/cluster-map.tpl';

/// Where the Controller's cluster map schema stands inside its tree.
const String controllerClusterMarking = 'server/domains/inventory/cluster-marking.ts';

/// The name the Controller's strict map schema is declared under.
const String clusterMarkingSchemaName = 'ClusterMarkingFileSchema';

/// The name the Controller declares the map directory under.
const String clusterMarkingDirName = 'CLUSTER_MARKING_DIR';

/// The tree the branch programs stamp the generators in.
const String generatorTree = 'argocd';

/// One place an ApplicationSet and the cluster maps disagree, and what the disagreement costs.
final class ClusterMapMismatch {
  /// Names [what] at [where], which cannot hold [because].
  const ClusterMapMismatch({required this.where, required this.what, required this.because});

  /// The file it stands in, as the tree names it.
  final String where;

  /// What the file does, in the words it is written in.
  final String what;

  /// Why that cannot work, in the words whoever wrote it reads.
  final String because;

  @override
  String toString() => '$where: $what $because';
}

// ── what the map's two writers write ────────────────────────────────────────

final RegExp _templateKey = RegExp(r'^([A-Za-z][A-Za-z0-9_-]*):', multiLine: true);

/// Every key the deploy programs' map [template] emits.
///
/// Read off the left-hand side of its lines, which is the whole of the file: the template is the
/// map with a slot in place of each value, so what it names IS what an installed cluster's map
/// carries.
Set<String> clusterMapTemplateKeysIn(String template) => <String>{
  for (final RegExpMatch found in _templateKey.allMatches(template)) found.group(1)!,
};

final RegExp _schemaKey = RegExp(
  r'^\s{2}(?:"([^"]+)"|([A-Za-z_][A-Za-z0-9_]*)):\s*z\.',
  multiLine: true,
);

/// Every key the Controller's strict map schema in [source] declares.
///
/// The schema is STRICT, which is what makes it the authority for a map the Controller writes: a
/// key it does not declare is refused on read and deleted on the next write, so the set it declares
/// is exactly the set a slave's map can carry.
///
/// Empty where the declaration is not found, which the audit treats as a refusal rather than as
/// "no key exists": a comparison against an empty set would report every key an appset reads and
/// bury the one that is actually wrong.
Set<String> clusterMapSchemaKeysIn(String source) {
  final RegExpMatch? block = RegExp(
    clusterMarkingSchemaName + r'\s*=\s*z\.object\(\{(.*?)\n\}\)',
    dotAll: true,
  ).firstMatch(source);
  if (block == null) {
    return const <String>{};
  }
  return <String>{
    for (final RegExpMatch found in _schemaKey.allMatches(block.group(1)!))
      found.group(1) ?? found.group(2)!,
  };
}

final RegExp _markingDir = RegExp(clusterMarkingDirName + r'\s*=\s*"([^"]+)"');

/// The directory the cluster maps stand in, as the Controller declares it in [source].
///
/// Read rather than written out here, because it is what decides which generators this check judges
/// at all: an appset whose files glob stands under it reads cluster maps, and one that does not is
/// another writer's business.
String? clusterMapDirectoryIn(String source) => _markingDir.firstMatch(source)?.group(1);

// ── what the programs answer with ───────────────────────────────────────────

YamlMap? _document(String yaml) {
  final Object? loaded = loadYaml(yaml);
  return loaded is YamlMap ? loaded : null;
}

Iterable<YamlMap> _stepsIn(YamlMap? document) {
  final Object? steps = document?['steps'];
  return steps is YamlList ? steps.whereType<YamlMap>() : const <YamlMap>[];
}

/// The answer behind each key of the cluster map, as the row of [program] that renders [template]
/// binds them.
///
/// This is the half a selector has to agree with. The map's `books-cluster` holds whatever the
/// answer named here holds, so a selector that matches on that key has to carry the value of THAT
/// answer and of no other.
Map<String, String> clusterMapValueSourcesIn(String program, {required String template}) {
  for (final YamlMap step in _stepsIn(_document(program))) {
    if (step['step'] != 'write_file_from_template' || step['template'] != template) {
      continue;
    }
    final Object? values = step['values'];
    if (values is! YamlMap) {
      continue;
    }
    final Map<String, String> sources = <String, String>{};
    for (final Object? key in values.keys) {
      final Object? binding = values[key];
      final Object? answer = binding is YamlMap ? binding['answer'] : null;
      if (key is String && answer is String) {
        sources[key] = answer;
      }
    }
    return sources;
  }
  return const <String, String>{};
}

final RegExp _marker = RegExp(r'^__[A-Z0-9_]+__$');

/// Whether [value] is a marker a branch program stamps rather than a value of its own.
bool isMarker(String value) => _marker.hasMatch(value);

/// Every marker [program] stamps into [tree], with the name of the answer it writes there.
///
/// Only rows that stamp from an ANSWER are collected. A row taking its value out of a file states a
/// fact about one machine's run rather than about the installation's answers, and there is nothing
/// on this side to hold it against.
///
/// A row naming no answer of its own falls back to the program's `defaults`, which is where these
/// programs put the answer most of their stamps read.
Map<String, String> stampedMarkersIn(String program, {required String tree}) {
  final YamlMap? document = _document(program);
  final Object? defaults = document?['defaults'];
  final Object? fallback = defaults is YamlMap ? defaults['value_answer'] : null;
  final Map<String, String> stamped = <String, String>{};
  for (final YamlMap step in _stepsIn(document)) {
    if (step['step'] != 'stamp_placeholder_in_tracked_files' || step['tree'] != tree) {
      continue;
    }
    final Object? placeholder = step['placeholder'];
    if (placeholder is! String || !isMarker(placeholder)) {
      continue;
    }
    final Object? answer = step.containsKey('value_file') ? null : step['value_answer'] ?? fallback;
    if (answer is String) {
      stamped[placeholder] = answer;
    }
  }
  return stamped;
}

/// The values each answer of [program] is closed to, out of its own `allowed:` list.
///
/// An answer with no such list is absent from the result rather than present with an empty set: the
/// two say opposite things, and a selector is judged against the difference — a literal is admitted
/// only under an answer that IS closed to a list of words.
Map<String, Set<String>> allowedAnswerValuesIn(String program) {
  final Object? answers = _document(program)?['answers'];
  final Map<String, Set<String>> allowed = <String, Set<String>>{};
  if (answers is! YamlList) {
    return allowed;
  }
  for (final YamlMap answer in answers.whereType<YamlMap>()) {
    final Object? name = answer['name'];
    final Object? values = answer['allowed'];
    if (name is String && values is YamlList) {
      allowed[name] = <String>{
        for (final Object? each in values)
          if (each is String) each,
      };
    }
  }
  return allowed;
}

// ── what an appset does with a map ──────────────────────────────────────────

/// Walks every document [yaml] holds, which is more than one where a file separates them with
/// `---` — the shape the project manifests have, and a reader taking only the first would judge a
/// file by its opening document alone.
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

/// Every path a git generator in [appset] selects files by.
///
/// Collected from the whole document rather than from a fixed place in it, because a matrix
/// generator nests its git generator one level further down and a reader that knew the depth would
/// stop seeing it the day a set gains a matrix.
Set<String> generatorFileGlobsIn(String appset) {
  final Set<String> globs = <String>{};
  _walkAll(appset, (YamlMap node) {
    final Object? files = node['files'];
    if (files is YamlList) {
      for (final YamlMap entry in files.whereType<YamlMap>()) {
        final Object? path = entry['path'];
        if (path is String) {
          globs.add(path);
        }
      }
    }
  });
  return globs;
}

/// Every label a selector in [appset] matches on, and the value it demands.
Map<String, String> matchLabelsIn(String appset) {
  final Map<String, String> labels = <String, String>{};
  _walkAll(appset, (YamlMap node) {
    final Object? matched = node['matchLabels'];
    if (matched is! YamlMap) {
      return;
    }
    for (final Object? key in matched.keys) {
      final Object? value = matched[key];
      if (key is String && value is String) {
        labels[key] = value;
      }
    }
  });
  return labels;
}

/// The roots a go template action may read that come from the generator itself rather than from the
/// file it read.
///
/// `values` is what the generator computes and declares beside its files; `path` is the file
/// metadata the git generator adds. Neither is a key of the map, so neither is held against one.
const Set<String> generatorProvidedRoots = <String>{'values', 'path'};

final RegExp _commentLine = RegExp(r'^\s*#.*$', multiLine: true);
final RegExp _action = RegExp(r'\{\{(.*?)\}\}', dotAll: true);
final RegExp _read = RegExp(r'(?<![\w.])\.([A-Za-z_][A-Za-z0-9_]*)');

/// The `index` form, which is not an alternative spelling but the ONLY way seven of the keys a
/// cluster map carries can be read at all.
///
/// `books-cluster`, `build-plane`, `unit-apex`, `platform-domain`, `alert-recipients`,
/// `catalog-repo` and `post-url` hold a hyphen, and a go template reads `.name` as a field name in
/// which a hyphen is subtraction. A file that needs one of them therefore writes
/// `{{ index . "books-cluster" }}`, and a reader knowing only the dot form watches half the map
/// while reporting on all of it.
///
/// Both string forms a go template takes are read: the interpreted `"..."` and the raw backtick one.
/// The interpreted one is also read where YAML has escaped it — an action standing inside a
/// double-quoted scalar has to write `\"` for its own quotes, and that spelling is the file's, not a
/// second syntax.
final RegExp _indexRead = RegExp(r'\bindex\s+\.\s+(?:\\?"([^"\\]*)\\?"|`([^`]*)`)');

/// Every key of the read file that a go template action in [appset] reads.
///
/// Read off the TEXT and not off the parsed document, because an action stands inside a scalar
/// wherever the template happens to need it — a name, a value, a block of patch — and a reader
/// bound to the places a key may stand would miss the next one.
///
/// Whole comment lines are dropped first: what a comment says about a key is prose, and judging it
/// would make an explanation of a past defect fail the tree.
Set<String> templateKeysReadIn(String appset) {
  final String code = appset.replaceAll(_commentLine, '');
  return <String>{
    for (final RegExpMatch action in _action.allMatches(code)) ...<String>{
      for (final RegExpMatch found in _read.allMatches(action.group(1)!))
        if (!generatorProvidedRoots.contains(found.group(1))) found.group(1)!,
      for (final RegExpMatch found in _indexRead.allMatches(action.group(1)!))
        if ((found.group(1) ?? found.group(2)) case final String key)
          if (!generatorProvidedRoots.contains(key)) key,
    },
  };
}

// ── the judgement ───────────────────────────────────────────────────────────

/// Everything [where] does with a cluster map that the map's writers cannot answer.
///
/// [reads] and [selects] are what the appset does; [carried] is every key a map may hold;
/// [writtenFrom] names the answer behind each of the keys the deploy programs write;
/// [stampedFrom] names the answer behind each marker the branch programs stamp into the generator
/// tree; [allowed] names the values an answer is closed to, for the answers that are.
List<ClusterMapMismatch> auditClusterMapAppset({
  required String where,
  required Set<String> reads,
  required Map<String, String> selects,
  required Set<String> carried,
  required Map<String, String> writtenFrom,
  required Map<String, String> stampedFrom,
  required Map<String, Set<String>> allowed,
}) {
  final List<ClusterMapMismatch> found = <ClusterMapMismatch>[];

  for (final String key in reads) {
    if (!carried.contains(key)) {
      found.add(
        ClusterMapMismatch(
          where: where,
          // The KEY, not a spelling of it. A hyphenated key can only be read through
          // `index . "key"`, so quoting it back as `{{ .key }}` would send the reader searching the
          // file for a line nobody wrote.
          what: 'reads the key "$key"',
          because:
              'which no writer of a cluster map writes — a map carries ${_listed(carried)}. Under '
              'missingkey=error one unknown key ends the whole reconcile, so not one Application '
              'of this set is created.',
        ),
      );
    }
  }

  for (final MapEntry<String, String> label in selects.entries) {
    final String key = label.key;
    final String value = label.value;
    if (!carried.contains(key)) {
      found.add(
        ClusterMapMismatch(
          where: where,
          what: 'selects on "$key: $value"',
          because:
              'and no writer of a cluster map writes a key of that name — a map carries '
              '${_listed(carried)}. A selector matching nothing produces zero Applications and '
              'reports no error at all.',
        ),
      );
      continue;
    }
    final String? answer = writtenFrom[key];
    if (answer == null) {
      found.add(
        ClusterMapMismatch(
          where: where,
          what: 'selects on "$key: $value"',
          because:
              'and the deploy programs write no such key into the map they render, so nothing '
              'a branch is stamped with can be held against what the map will hold. Select on a '
              'key the programs write, or the two sides agree only by accident.',
        ),
      );
      continue;
    }
    if (isMarker(value)) {
      final String? source = stampedFrom[value];
      if (source == null) {
        found.add(
          ClusterMapMismatch(
            where: where,
            what: 'selects on "$key: $value"',
            because:
                'and no branch program stamps that marker into the $generatorTree tree from an '
                'answer. It reaches a cluster as the marker itself, which no map carries, and a '
                'selector matching nothing produces zero Applications and reports no error at all.',
          ),
        );
      } else if (source != answer) {
        found.add(
          ClusterMapMismatch(
            where: where,
            what: 'selects on "$key: $value"',
            because:
                'which is stamped from the answer "$source", while a map\'s "$key" is written from '
                'the answer "$answer". Two answers an operator may answer differently are not one '
                'value, and where they differ this selector matches nothing and reports no error '
                'at all.',
          ),
        );
      }
      continue;
    }
    final Set<String>? words = allowed[answer];
    if (words == null) {
      found.add(
        ClusterMapMismatch(
          where: where,
          what: 'selects on "$key: $value"',
          because:
              'a literal, while a map\'s "$key" holds whatever the answer "$answer" holds — an '
              'installation\'s own value, which no file shipping to every installation can name. '
              'Stamp a marker from that answer instead; a selector matching nothing produces zero '
              'Applications and reports no error at all.',
        ),
      );
    } else if (!words.contains(value)) {
      found.add(
        ClusterMapMismatch(
          where: where,
          what: 'selects on "$key: $value"',
          because:
              'a literal the answer "$answer" does not allow — it admits ${_listed(words)}. No map '
              'can carry it, and a selector matching nothing produces zero Applications and '
              'reports no error at all.',
        ),
      );
    }
  }

  return found;
}

String _listed(Set<String> values) {
  final List<String> sorted = values.toList()..sort();
  return sorted.isEmpty ? 'nothing' : sorted.map((String each) => '"$each"').join(', ');
}
