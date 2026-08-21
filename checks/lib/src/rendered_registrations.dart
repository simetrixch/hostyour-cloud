/// rendered-registrations — a registration an installation's programs write by hand has to parse
/// under the schema the Controller reads it back with.
///
/// **Why a hand-written registration exists at all.** Every registration is written by the
/// Controller — `server/domains/onboarding/registry.ts` calls itself the ONLY writer of
/// `registrations/**`, and it serializes each value as JSON, so a boolean is written unquoted and
/// the types are the schema's by construction. One file is the exception: the platform's own
/// Controller had no registration, so a first installation could not build the one image it needs
/// to run the thing that writes registrations. An installation program renders that one from a
/// template.
///
/// **A template is not JSON-serialized, so nothing makes its types right.** It is written by a
/// person, in YAML, and YAML is where `false` and `"false"` are two different things. That is not
/// hypothetical: the template rendered `suspended: "false"`, a string, against
/// `suspended: z.boolean()`, and the consequence was not a message about that field. It was gate
/// G16 refusing EVERY OTHER consumer's onboarding on a fresh installation, with a message about
/// build-name uniqueness — because the reader throws where a stage scan would skip.
///
/// **The selector is NOT what decides the type, and that was measured.** ArgoCD flattens a
/// registration's parameters for the selector with `fmt.Sprintf("%v", v)`, so an unquoted `false`
/// and a quoted `"false"` are the same string to it — see [registrationSelectorsIn] and the reading
/// of ArgoCD's own source above it. Both spellings match the fan-out. Only the schema tells them
/// apart, which is why this check reads the schema and not the selector.
///
/// **What is found, and how.** Not a named file: the rows themselves. A program row that writes a
/// template to a path under `registrations/` is a rendered registration whatever it is called, so a
/// second one added later is checked the day it is written and not the day it breaks something.
///
/// **WHAT IT DOES NOT REACH.**
///
///   * The registrations the Controller WRITES. They stand on the install branch each generator
///     names as its `revision:`, not on this one, and their types are the schema's by construction
///     because every value goes through `JSON.stringify`. What one holds is measured by the
///     Controller's own suite.
///   * A value a step SUBSTITUTES. The template is read as it stands, so a slot the row fills at
///     run time is judged as the slot and not as what lands in the file.
///   * A field no schema declares. Only the names both sides carry are held; an unknown key is
///     refused where the file is read, if it is refused at all.
///   * Whether a row RUNS. A row behind a `when:` is read like any other, so this says what would
///     be written and never that it was.
///   * A zod type it does not know, which admits everything rather than guessing.
library;

import 'package:yaml/yaml.dart';

import 'registration_selectors.dart';

/// The path segment that makes a written file a registration.
const String registrationsPath = 'registrations/';

/// The step kind that renders one.
const String renderStep = 'write_file_from_template';

/// One registration an installation program renders from a template.
final class RenderedRegistration {
  /// A registration written by [program] from [template] to [path].
  const RenderedRegistration({required this.program, required this.template, required this.path});

  /// The program file that writes it, as the caller names it.
  final String program;

  /// The template it is rendered from, as the row names it.
  final String template;

  /// Where the row writes it.
  final String path;

  @override
  String toString() => '$program renders $template to $path';
}

/// Every row of [document] that renders a registration, named by [program].
///
/// The steps are read as data and never as text: a row is a map with a `step`, and what makes it
/// this kind is that key's value and the path it writes, not the words around it.
List<RenderedRegistration> renderedRegistrationsIn({
  required String program,
  required Object? document,
}) {
  final List<RenderedRegistration> found = <RenderedRegistration>[];
  if (document is! YamlMap) {
    return found;
  }
  final Object? steps = document['steps'];
  if (steps is! YamlList) {
    return found;
  }
  for (final Object? row in steps) {
    if (row is! YamlMap || row['step'] != renderStep) {
      continue;
    }
    final Object? path = row['path'];
    final Object? template = row['template'];
    if (path is! String || !path.contains(registrationsPath)) {
      continue;
    }
    found.add(
      RenderedRegistration(
        program: program,
        template: template is String ? template : '<no template named>',
        path: path,
      ),
    );
  }
  return found;
}

/// A value a rendered registration carries that the schema's declared type does not admit.
final class RenderedFinding {
  /// [field] of [template], as [program] renders it, holds [held], and [declaredIn] declares it
  /// [declared].
  const RenderedFinding({
    required this.program,
    required this.template,
    required this.field,
    required this.held,
    required this.declared,
    required this.declaredIn,
  });

  /// The program whose row renders it. Two programs rendering ONE template is a fact worth reading
  /// off a refusal rather than a repetition to skip over: it is two writers of one file.
  final String program;

  /// The template the value stands in.
  final String template;

  /// The field's name.
  final String field;

  /// What the YAML parse answered, in the words a reader can act on.
  final String held;

  /// The zod type the schema declares, without its `z.`.
  final String declared;

  /// The schema that declares it.
  final String declaredIn;

  @override
  String toString() =>
      '$program renders $template, where "$field" is $held, and $declaredIn declares it '
      'z.$declared — the Controller '
      'refuses the file, and what an operator is told is whatever the first reader past the '
      'refusal says';
}

/// Every value in [rendered] whose type no schema declaring that field admits.
///
/// A field NO schema declares is not a finding: a registration may carry what the writer of that
/// file and its readers agree on, and a schema that refuses an unknown key refuses it where the
/// file is read. What is held here is only the fields both sides name.
List<RenderedFinding> auditRenderedRegistrations({
  required Map<RenderedRegistration, String> rendered,
  required List<DeclaredField> fields,
}) {
  final List<RenderedFinding> findings = <RenderedFinding>[];
  rendered.forEach((RenderedRegistration each, String body) {
    final Object? document = loadYaml(body);
    if (document is! YamlMap) {
      return;
    }
    document.forEach((Object? key, Object? value) {
      if (key is! String) {
        return;
      }
      final List<DeclaredField> declaring = fields
          .where((DeclaredField field) => field.name == key && field.type != null)
          .toList();
      if (declaring.isEmpty ||
          declaring.any((DeclaredField field) => _admits(field.type!, value))) {
        return;
      }
      final DeclaredField first = declaring.first;
      findings.add(
        RenderedFinding(
          program: each.program,
          template: each.template,
          field: key,
          held: _describe(value),
          declared: first.type!,
          declaredIn: first.schema,
        ),
      );
    });
  });
  return findings;
}

/// Whether a value parsed out of YAML is one a zod [type] takes.
///
/// Only the types a registration is written in are answered. An unknown one admits everything,
/// because a check that guessed at a type it does not know would report a value that is fine — and
/// a field whose declaration names another schema instead of a zod type carries no readable type at
/// all, so it never reaches here.
bool _admits(String type, Object? value) => switch (type) {
  'boolean' => value is bool,
  'string' => value is String,
  'number' => value is num,
  'array' => value is List,
  _ => true,
};

/// What a value is, in the words a refusal is read with.
String _describe(Object? value) => switch (value) {
  final String text => 'the string "$text"',
  final bool held => 'the boolean $held',
  final num held => 'the number $held',
  final List<Object?> _ => 'a list',
  null => 'null',
  _ => 'a $value',
};
