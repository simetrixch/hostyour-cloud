import 'package:yaml/yaml.dart';

import '../installation.dart';
import '../tree/source_tree.dart';
import 'named_value_file.dart';

/// One ApplicationSet of this tree, read for the values files its sources name.
///
/// IT IS READ LINE BY LINE AND NOT AS A DOCUMENT, and that is forced rather than chosen. Two of the
/// four generators under `argocd/<stage>/apps/` state their sources inside `templatePatch`, which is
/// a YAML block SCALAR holding go-template directives — `{{- range .sources }}` and `{{- if has
/// "postgresql" .services }}` are lines of a string, and a YAML reader handed that string gives back
/// the string. A line scan reads both halves the same way and carries the line number a person opens
/// the file at.
///
/// WHAT A SOURCE CONTRIBUTES is its repository and its chart path, because an entry means nothing
/// without them: `values-common.yaml` is a file of whichever repository the source it rides on
/// reads, under whichever directory that source deploys. `$values/...` and `$pins/...` are the other
/// shape — ArgoCD resolves a `$<name>` prefix against the source that declared `ref: <name>`, which
/// is a DIFFERENT source of the same Application and usually a different repository.
///
/// A PARAMETER IS EXPANDED ONLY WHERE THIS FILE STATES IT. `path: "apps/{{ .name }}"` in the
/// platform catalog is expandable — the names stand as literal `list` elements in the same manifest,
/// so the generator produces exactly those Applications and no others. `path: {{ .chart | quote }}`
/// in the tenant generator is not: that value arrives from a registration on another repository's
/// books branch, and a check that guessed it would be inventing the thing it is meant to measure.
final class GeneratorManifest {
  const GeneratorManifest._({required this.path, required this.text, required this.parameters});

  /// Every ApplicationSet in the chart material of [tree], in path order.
  static List<GeneratorManifest> allIn(SourceTree tree) => <GeneratorManifest>[
    for (final String path in tree.chartMaterial)
      if (_at(path, tree) case final GeneratorManifest manifest) manifest,
  ];

  /// The manifest at [path] of [tree], or null when that path carries no ApplicationSet.
  ///
  /// The kind is read at column 0 only, so a `kind: ApplicationSet` standing indented — inside a
  /// comment, a block scalar or a CustomResourceDefinition naming the kind it defines — is not one.
  static GeneratorManifest? _at(String path, SourceTree tree) {
    final String? text = tree.textOf(path);
    if (text == null || !_kind.hasMatch(text)) {
      return null;
    }
    return GeneratorManifest._(path: path, text: text, parameters: _literalParametersOf(text));
  }

  /// Where the manifest stands, relative to the repository root.
  final String path;

  /// Its bytes.
  final String text;

  /// The parameter sets its own `list` generators state as literals, in the order they stand.
  ///
  /// Empty for a generator reading files of another repository, which is what makes such a
  /// generator's parameters unexpandable here rather than guessed at.
  final List<Map<String, String>> parameters;

  /// Whether the manifest names values files at all, read from its bytes rather than from the scan.
  ///
  /// This is the other side of the scan: a manifest that says `valueFiles:` and yields no entry has
  /// a list written in a shape the reader cannot follow, and a check silently short one generator
  /// looks exactly like one that found nothing wrong.
  bool get namesValueFiles => text.contains('valueFiles:');

  /// Every values file the sources of this manifest name, in the order they stand.
  List<NamedValueFile> namedValueFiles() {
    final _Reading reading = _read();
    return <NamedValueFile>[
      for (final _Entry entry in reading.entries) ..._place(entry, reading.refs),
    ];
  }

  _Reading _read() {
    final List<String> lines = SourceTree.linesOf(text);
    final Map<String, String> anchors = <String, String>{};
    final Map<String, String> refs = <String, String>{};
    final List<_Entry> entries = <_Entry>[];

    String? repository;
    String? chartPath;
    int collectingUnder = -1;

    for (int at = 0; at < lines.length; at++) {
      final String line = _withoutComment(lines[at]);
      final String trimmed = line.trim();

      if (collectingUnder >= 0) {
        // A comment, a blank and a go-template directive all stand INSIDE these lists and none of
        // them ends one; a `{{- range .valueFiles }}` around an entry is exactly the shape the
        // tenant generator writes.
        if (trimmed.isEmpty || trimmed.startsWith('#') || trimmed.startsWith('{{')) {
          continue;
        }
        if (_indentOf(line) > collectingUnder && trimmed.startsWith('- ')) {
          entries.add(
            _Entry(
              line: at + 1,
              text: _unquoted(trimmed.substring(2).trim()),
              repository: repository,
              chartPath: chartPath,
            ),
          );
          continue;
        }
        collectingUnder = -1;
      }

      final Match? source = _sourceRepository.firstMatch(line);
      if (source != null) {
        repository = _resolveRepository(source.group(1)!.trim(), anchors);
        chartPath = null;
        continue;
      }
      if (repository != null) {
        final Match? named = _chartPath.firstMatch(line);
        if (named != null) {
          chartPath = _unquoted(named.group(1)!.trim());
          continue;
        }
        final Match? declared = _sourceRef.firstMatch(line);
        if (declared != null) {
          refs[declared.group(1)!] = repository;
          continue;
        }
      }
      final Match? list = _valueFilesKey.firstMatch(line);
      if (list != null) {
        collectingUnder = list.group(1)!.length;
      }
    }

    return _Reading(refs: refs, entries: entries);
  }

  List<NamedValueFile> _place(_Entry entry, Map<String, String> refs) {
    if (entry.text.startsWith(r'$')) {
      final int slash = entry.text.indexOf('/');
      if (slash < 0) {
        return <NamedValueFile>[
          _standing(entry, const Unplaceable('it names a source ref and no path behind it')),
        ];
      }
      final String ref = entry.text.substring(1, slash);
      final String? repository = refs[ref];
      if (repository == null) {
        return <NamedValueFile>[
          _standing(
            entry,
            Unplaceable(
              'it reads through \$$ref and no source of this generator declares `ref: $ref`',
            ),
          ),
        ];
      }
      return _under(entry, repository, entry.text.substring(slash + 1));
    }

    final String? repository = entry.repository;
    if (repository == null) {
      return <NamedValueFile>[
        _standing(entry, const Unplaceable('it is relative to a source that names no repository')),
      ];
    }
    final String? chartPath = entry.chartPath;
    if (chartPath == null) {
      return <NamedValueFile>[
        _standing(entry, const Unplaceable('it is relative to a source that names no chart path')),
      ];
    }
    return _under(entry, repository, '$chartPath/${entry.text}');
  }

  List<NamedValueFile> _under(_Entry entry, String repository, String path) {
    if (repository != thisRepository) {
      return <NamedValueFile>[_standing(entry, InAnotherRepository(repository))];
    }
    final List<String>? expanded = _expanded(path);
    if (expanded == null) {
      return <NamedValueFile>[
        _standing(entry, NamedByAGeneratorParameter(_firstExpressionIn(path))),
      ];
    }
    return <NamedValueFile>[
      for (final String each in expanded) _standing(entry, InThisRepository(each)),
    ];
  }

  NamedValueFile _standing(_Entry entry, ValueFileStanding standing) =>
      NamedValueFile(manifest: path, line: entry.line, entry: entry.text, standing: standing);

  /// Every path [path] can be, or null when it carries something this manifest cannot resolve.
  ///
  /// `__STAGE__` is the one placeholder that stands inside a values path. It is substituted from
  /// global.env by the chart that emits the generator carrying it
  /// (apps/consumer-build/templates/applicationset.yaml), and global.env is one of the three stages,
  /// so the file has to be there for whichever stage the installation is.
  List<String>? _expanded(String path) {
    final List<String> withStages = path.contains(_stagePlaceholder)
        ? <String>[for (final String stage in stages) path.replaceAll(_stagePlaceholder, stage)]
        : <String>[path];
    final List<String> found = <String>[];
    for (final String each in withStages) {
      final List<String>? more = _withoutExpressions(each);
      if (more == null) {
        return null;
      }
      found.addAll(more);
    }
    return found;
  }

  List<String>? _withoutExpressions(String path) {
    final Match? expression = _expression.firstMatch(path);
    if (expression == null) {
      return <String>[path];
    }
    final List<String>? values = _parameterValuesOf(expression.group(1)!.trim());
    if (values == null) {
      return null;
    }
    final List<String> found = <String>[];
    for (final String value in values) {
      final List<String>? more = _withoutExpressions(
        path.replaceRange(expression.start, expression.end, value),
      );
      if (more == null) {
        return null;
      }
      found.addAll(more);
    }
    return found;
  }

  /// The values this manifest's own literal parameter sets give [expression], or null when it is
  /// not a bare parameter or when a single parameter set fails to state it.
  ///
  /// ALL of them have to state it. A list where one element carries the key and another does not is
  /// a generator producing an Application whose path this reader would have to invent, and inventing
  /// one is how a check comes to require a file nobody named.
  List<String>? _parameterValuesOf(String expression) {
    final Match? parameter = _bareParameter.firstMatch(expression);
    if (parameter == null || parameters.isEmpty) {
      return null;
    }
    final String key = parameter.group(1)!;
    final Set<String> values = <String>{};
    for (final Map<String, String> each in parameters) {
      final String? value = each[key];
      if (value == null) {
        return null;
      }
      values.add(value);
    }
    final List<String> sorted = values.toList(growable: false)..sort();
    return sorted;
  }

  static String _firstExpressionIn(String path) =>
      _expression.firstMatch(path)?.group(0) ?? _stagePlaceholder;

  /// The parameter sets stated as literal `list` elements anywhere in [text].
  ///
  /// `elementsYaml` is deliberately not read: the tenant generator fills it from
  /// `{{ .members | toJson }}`, so its elements are a registration's and not this file's.
  static List<Map<String, String>> _literalParametersOf(String text) {
    final List<Map<String, String>> found = <Map<String, String>>[];
    try {
      _walk(loadYaml(text), found);
    } on YamlException {
      return const <Map<String, String>>[];
    }
    return found;
  }

  static void _walk(Object? node, List<Map<String, String>> into) {
    if (node is YamlList) {
      for (final Object? each in node) {
        _walk(each, into);
      }
      return;
    }
    if (node is! YamlMap) {
      return;
    }
    final Object? list = node['list'];
    if (list is YamlMap) {
      final Object? elements = list['elements'];
      if (elements is YamlList) {
        for (final Object? element in elements) {
          if (element is YamlMap) {
            into.add(<String, String>{
              for (final MapEntry<Object?, Object?> pair in element.entries)
                if (pair.key case final String key)
                  if (pair.value case final String value) key: value,
            });
          }
        }
      }
    }
    for (final Object? value in node.values) {
      _walk(value, into);
    }
  }

  /// The repository [token] names, resolving the YAML anchors the manifests write on it.
  ///
  /// `&repo "https://…"` on the first source and `*repo` on the second is how these files state the
  /// repository once; a scan that read the alias as a URL would place every second source nowhere.
  static String _resolveRepository(String token, Map<String, String> anchors) {
    if (token.startsWith('*')) {
      return anchors[token.substring(1).trim()] ?? token;
    }
    if (token.startsWith('&')) {
      final int space = token.indexOf(' ');
      if (space < 0) {
        return token;
      }
      final String value = _unquoted(token.substring(space + 1).trim());
      anchors[token.substring(1, space)] = value;
      return value;
    }
    return _unquoted(token);
  }

  static String _withoutComment(String line) {
    final int hash = line.indexOf(' #');
    return hash < 0 ? line : line.substring(0, hash);
  }

  static String _unquoted(String value) {
    if (value.length >= 2 && (value.startsWith('"') || value.startsWith("'"))) {
      if (value.endsWith(value[0])) {
        return value.substring(1, value.length - 1);
      }
    }
    return value;
  }

  static int _indentOf(String line) => line.length - line.trimLeft().length;

  static const String _stagePlaceholder = '__STAGE__';

  static final RegExp _kind = RegExp(r'^kind:[ \t]*ApplicationSet[ \t]*(#.*)?$', multiLine: true);
  static final RegExp _sourceRepository = RegExp(r'^\s*-\s+repoURL:\s*(\S.*)$');
  static final RegExp _chartPath = RegExp(r'^\s+path:\s*(\S.*)$');
  static final RegExp _sourceRef = RegExp(r'^\s+ref:\s*(\S+)\s*$');
  static final RegExp _valueFilesKey = RegExp(r'^(\s*)valueFiles:\s*$');
  static final RegExp _expression = RegExp(r'\{\{(.*?)\}\}');
  static final RegExp _bareParameter = RegExp(r'^\.([A-Za-z_][A-Za-z0-9_]*)$');
}

/// One entry of one list, with the source it rides on, before it has been placed.
final class _Entry {
  const _Entry({
    required this.line,
    required this.text,
    required this.repository,
    required this.chartPath,
  });

  final int line;
  final String text;
  final String? repository;
  final String? chartPath;
}

/// What one pass over a manifest produced.
final class _Reading {
  const _Reading({required this.refs, required this.entries});

  final Map<String, String> refs;
  final List<_Entry> entries;
}
