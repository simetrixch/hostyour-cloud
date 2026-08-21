/// registration-selectors — every ApplicationSet post-selector over `registrations/**` matches a
/// value the Controller's registration schemas can put in such a file.
///
/// **What ArgoCD actually compares, read out of the version this tree pins.**
/// `slaves/slave/Chart.yaml:55-57` pins the `argo-cd` chart at 10.2.1 and `:4` its `appVersion:` at
/// `v3.4.5`, the same number `platform/versions.yaml:505` pins the CLI at. At that tag the way from
/// a registration file to a selector decision is four steps:
///
///   * `applicationset/generators/git.go:227` parses the file with
///     `yaml.Unmarshal(fileContent, &singleObj)` into a `map[string]any`, so an unquoted `false` is
///     a Go `bool` and a quoted `"false"` is a Go `string`;
///   * `git.go:243-244` copies that map out unchanged under `goTemplate: true`
///     (`maps.Copy(params, objectFound)`) — nothing is converted on the way out of the generator;
///   * `applicationset/generators/generator_spec_processor.go:126-137` flattens the parameter set
///     FOR THE SELECTOR ALONE, with `out[k] = fmt.Sprintf("%v", v)`, and hands the resulting
///     `map[string]string` to `selector.Matches(labels.Set(flatParam))` at `:89`;
///   * `applicationset/utils/selector.go:214-220` decides: `if !ls.Has(r.key) { return false }`,
///     then a plain string equality against the selector's own value.
///
/// So a `matchLabels` value is held against the PRINTED form of whatever the file holds, and
/// `fmt.Sprintf("%v", false)` prints `false`. A YAML boolean `false` and a YAML string `"false"` are
/// the same thing to the selector, which is why the selector is not what decides the field's type.
///
/// **The type is decided by the other reader, and it is a boolean.** The Controller's
/// `shared/consumer.ts` declares `suspended: z.boolean().default(false)` in
/// `ConsumerRegistrationSchema`, `shared/tenant.ts` declares it the same way in
/// `TenantRegistrationSchema`, and `server/domains/onboarding/registry.test.ts:174-186` measures
/// both spellings against that schema: the boolean parses, the quoted string is refused with
/// `expected: "boolean"`. The selector value stays QUOTED all the same — `matchLabels` is
/// `map[string]string`, so an unquoted `false` there is not a selector that matches nothing but a
/// manifest the API server refuses on apply.
///
/// **Why silence is the failure mode this holds off.** A files generator that matches fewer files
/// is not an error — `apps/consumer-build/files/applicationset.yaml:25-28` says so in its own
/// words. A selector key no registration carries makes `selector.go:217` answer false for EVERY
/// unit, so the build fan-out renders no `<unit>-build` Application at all, and nothing reports it:
/// the ApplicationSet stays Healthy with zero children.
///
/// **Neither side is LISTED here, both are READ.** The selectors come out of the ApplicationSet
/// documents of this tree, the fields out of the `z.object({...})` blocks of the Controller's
/// registration schemas. A hand-kept list of either would go on passing the day the other side
/// moved.
///
/// **WHAT IT DOES NOT REACH.** It reads the DECLARED type and not the values a writer really puts
/// in a file: a field declared `z.string()` admits every selector value, so a selector on one is
/// carried by nothing here. It does not read the registrations themselves — none stand on this
/// branch, they stand on the install branch the generators name as their `revision:` — so a
/// registration written in the losing spelling is refused by the Controller's schema and by nothing
/// in this gate. It does not read `matchExpressions`: a generator over `registrations/**` that uses
/// one is refused as unreadable rather than judged. And it says nothing about a generator whose
/// files stand anywhere else — `argocd/apps/slaves-appset.yaml` selects cluster maps out of
/// `clusters/active/*.yaml`, whose keys are `appset-cluster-map-keys`' subject and not this one's.
library;

/// The path prefix that makes a generator's files registrations.
const String registrationsPrefix = 'registrations/';

/// One `matchLabels` pair an ApplicationSet generator over `registrations/**` selects by.
final class RegistrationSelector {
  /// Records that [appset] selects the files of [glob] by [key] matching [value].
  const RegistrationSelector({
    required this.appset,
    required this.glob,
    required this.key,
    required this.value,
    required this.valueIsString,
  });

  /// The ApplicationSet, as a path that names the file somebody has to open.
  final String appset;

  /// The `registrations/` glob the generator this selector belongs to reads.
  final String glob;

  /// The parameter key the selector matches by.
  final String key;

  /// The value it matches, printed the way a finding says it.
  final String value;

  /// Whether the YAML made a string of it, which is what `matchLabels` may hold.
  final bool valueIsString;
}

/// One field a registration schema of the Controller declares.
final class DeclaredField {
  /// Records that [schema] declares [name] as [type].
  const DeclaredField({required this.schema, required this.name, required this.type});

  /// The schema, by the name the Controller exports it under.
  final String schema;

  /// The field name, which is the key it stands under in a registration file.
  final String name;

  /// The zod type it is declared in — `boolean`, `string`, `array` — or null where the declaration
  /// names another schema instead of a zod type, and the type is not readable from the line.
  final String? type;
}

/// The strings ArgoCD's selector can ever see for a value of a given zod type.
///
/// The set is what `fmt.Sprintf("%v", v)` prints for the Go values that type parses to
/// (`generator_spec_processor.go:134`), so a selector value outside it matches nothing — for every
/// registration, forever, without an error anywhere. Only the types with a CLOSED set of printings
/// are in here: a `string` field admits any value and a selector on one cannot be held to anything.
const Map<String, Set<String>> argocdLabelValues = <String, Set<String>>{
  'boolean': <String>{'true', 'false'},
};

/// One selector that cannot match what the Controller writes.
final class SelectorFinding {
  /// Records that [selector] is wrong [because].
  const SelectorFinding({required this.selector, required this.because});

  /// The selector nothing will satisfy.
  final RegistrationSelector selector;

  /// What is wrong with it, in the words whoever wrote it reads.
  final String because;

  /// The one line a refusal says about it.
  @override
  String toString() =>
      '${selector.appset} selects ${selector.glob} by "${selector.key}: ${selector.value}" — '
      '$because';
}

/// Every `matchLabels` pair of [document] that selects files under [registrationsPrefix], where
/// [document] is the parsed YAML of the ApplicationSet standing at [appset].
///
/// A generator entry is taken for a registration reader when a `files:` `path:` ANYWHERE inside it
/// begins with the prefix, because the entry that carries the selector is not always the one that
/// carries the files: `argocd/apps/tenants-appset.yaml:77-90` puts the git generator inside a
/// `matrix:` and the selector beside the matrix, and it is the OUTER entry's selector ArgoCD
/// applies (`generator_spec_processor.go:89` reads `requestedGenerator.Selector`).
///
/// Throws a [FormatException] naming [appset] where such a generator carries a selector this cannot
/// read down to its pairs: a selector held to nothing is the pass this check exists to refuse.
List<RegistrationSelector> registrationSelectorsIn({
  required String appset,
  required Object? document,
}) {
  final List<RegistrationSelector> found = <RegistrationSelector>[];
  final Object? spec = document is Map ? document['spec'] : null;
  final Object? generators = spec is Map ? spec['generators'] : null;
  if (generators is! List) {
    return found;
  }
  for (final Object? entry in generators) {
    if (entry is! Map) {
      continue;
    }
    final List<String> globs = _registrationGlobsIn(entry);
    if (globs.isEmpty) {
      continue;
    }
    final Object? selector = entry['selector'];
    if (selector == null) {
      continue;
    }
    for (final MapEntry<String, Object?> pair in _matchLabelsOf(appset, selector).entries) {
      found.add(
        RegistrationSelector(
          appset: appset,
          glob: globs.first,
          key: pair.key,
          value: '${pair.value}',
          valueIsString: pair.value is String,
        ),
      );
    }
  }
  return found;
}

/// The `matchLabels` of [selector], or the refusal that [appset] wrote one this cannot read.
Map<String, Object?> _matchLabelsOf(String appset, Object? selector) {
  Never unreadable(String detail) => throw FormatException(
    '$appset selects files under $registrationsPrefix with a selector $detail — what cannot be read '
    'cannot be held to the fields the Controller declares, so this is an error and never a pass',
  );

  if (selector is! Map) {
    unreadable('that is not a mapping');
  }
  if (selector['matchExpressions'] != null) {
    unreadable('written as matchExpressions');
  }
  final Object? labels = selector['matchLabels'];
  if (labels is! Map) {
    unreadable('carrying no matchLabels mapping');
  }
  final Map<String, Object?> pairs = <String, Object?>{};
  for (final MapEntry<Object?, Object?> pair in labels.entries) {
    final Object? key = pair.key;
    if (key is! String) {
      unreadable('whose matchLabels holds a key that is not a string');
    }
    pairs[key] = pair.value;
  }
  return pairs;
}

/// Every `files:` `path:` under [node] that begins with [registrationsPrefix], sorted so the answer
/// does not move with the order a mapping is read in.
List<String> _registrationGlobsIn(Object? node) {
  final List<String> found = <String>[];
  void walk(Object? each) {
    if (each is Map) {
      final Object? files = each['files'];
      if (files is List) {
        for (final Object? file in files) {
          final Object? path = file is Map ? file['path'] : null;
          if (path is String && path.startsWith(registrationsPrefix)) {
            found.add(path);
          }
        }
      }
      for (final Object? value in each.values) {
        walk(value);
      }
    } else if (each is List) {
      for (final Object? value in each) {
        walk(value);
      }
    }
  }

  walk(node);
  found.sort();
  return found;
}

/// The line a registration schema's declaration opens on.
final RegExp _schemaOpening = RegExp(r'^export const (\w*RegistrationSchema) = z\s*$');

/// A field line inside a `z.object({...})` block: the name, and the head of what it is declared as.
///
/// The HEAD alone, because that is what carries the type — the rest of the chain is refinements, a
/// regular expression or a default, and a line-end comment may hold anything at all.
final RegExp _fieldLine = RegExp(r'^    ([A-Za-z_]\w*)\s*:\s*(z\.[A-Za-z]\w*|[A-Za-z_]\w*)');

/// A field written in the shorthand that names an imported schema and nothing else.
final RegExp _shorthandField = RegExp(r'^    ([A-Za-z_]\w*),\s*$');

/// Every field the registration schemas of [source] declare, where [source] is one of the
/// Controller's shared TypeScript modules.
///
/// Read off the lines rather than parsed, because what is needed is one word per field and the file
/// is TypeScript, not data. The block is the run of lines between the `.object({` that follows the
/// export and the `})` that closes it at the same indentation; a declaration of another shape ends
/// the reading of that schema rather than being guessed at.
List<DeclaredField> registrationFieldsIn(String source) {
  final List<DeclaredField> found = <DeclaredField>[];
  String? schema;
  bool inObject = false;
  for (final String raw in source.split('\n')) {
    final String line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
    if (schema == null) {
      schema = _schemaOpening.firstMatch(line)?.group(1);
      inObject = false;
      continue;
    }
    if (!inObject) {
      if (line.trim() == '.object({') {
        inObject = true;
      } else if (line.trim().isNotEmpty) {
        schema = null;
      }
      continue;
    }
    if (line == '  })') {
      schema = null;
      inObject = false;
      continue;
    }
    final RegExpMatch? field = _fieldLine.firstMatch(line);
    if (field != null) {
      final String head = field.group(2)!;
      found.add(
        DeclaredField(
          schema: schema,
          name: field.group(1)!,
          type: head.startsWith('z.') ? head.substring(2) : null,
        ),
      );
      continue;
    }
    final RegExpMatch? shorthand = _shorthandField.firstMatch(line);
    if (shorthand != null) {
      found.add(DeclaredField(schema: schema, name: shorthand.group(1)!, type: null));
    }
  }
  return found;
}

/// Every selector of [selectors] that nothing the Controller writes into a registration can satisfy,
/// judged against the [fields] its registration schemas declare.
List<SelectorFinding> auditRegistrationSelectors({
  required List<RegistrationSelector> selectors,
  required List<DeclaredField> fields,
}) {
  final List<SelectorFinding> found = <SelectorFinding>[];
  for (final RegistrationSelector each in selectors) {
    if (!each.valueIsString) {
      found.add(
        SelectorFinding(
          selector: each,
          because:
              'the value is not a string, and a matchLabels mapping is map[string]string — the API '
              'server refuses the whole ApplicationSet on apply, so no unit is fanned out at all',
        ),
      );
      continue;
    }
    final List<DeclaredField> declared = <DeclaredField>[
      for (final DeclaredField field in fields)
        if (field.name == each.key) field,
    ];
    if (declared.isEmpty) {
      found.add(
        SelectorFinding(
          selector: each,
          because:
              'no registration schema of the Controller declares a field of that name, so no '
              'registration carries the key — selector.go:217 answers false for every parameter set '
              'without it, and a files generator that matches fewer files is not an error',
        ),
      );
      continue;
    }
    for (final DeclaredField field in declared) {
      if (field.type == null) {
        found.add(
          SelectorFinding(
            selector: each,
            because:
                '${field.schema} declares "${field.name}" by naming another schema, so the type it '
                'parses to is not readable from the declaration and the value cannot be held to the '
                'form ArgoCD prints',
          ),
        );
        continue;
      }
      final Set<String>? printed = argocdLabelValues[field.type];
      if (printed != null && !printed.contains(each.value)) {
        found.add(
          SelectorFinding(
            selector: each,
            because:
                '${field.schema} declares "${field.name}" as z.${field.type}(), which reaches the '
                'selector printed as ${printed.map((String each) => '"$each"').join(' or ')} '
                '(generator_spec_processor.go:134) — this value is none of them, so the selector '
                'matches no registration and nothing says so',
          ),
        );
      }
    }
  }
  return found;
}
