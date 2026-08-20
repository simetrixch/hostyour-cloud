/// channel-table-single — the stages a release channel may reach are stated in ONE place.
///
/// **WHAT THE CEILING DECIDES.** A release carries its channel inside the tag itself
/// (`<major>.<minor>.<patch>-<channel>-<stamp>`), and the channel decides how far that release may
/// travel: which stages a pin naming it may be written for. Three points enforce it, and they reach
/// the table by two different routes.
///
/// The `gate-stage` task of every `<unit>-release` Pipeline refuses before any clone, and the `bump`
/// task refuses again before it writes a pin. Both read the table out of the `CHANNEL_STAGES`
/// environment variable that `apps/consumer-build/templates/pipeline-release.yaml` renders from
/// `.Values.global.channelStages` — the values chain, resolved by Helm at render time.
///
/// A cluster release refuses BEFORE its writing point, not at it: `ceilingCheck` in
/// `hostyour-manager/server/domains/runs/defs/release.ts` runs as the `attest-target` step's own
/// check, ahead of the `set-pin` step that commits `release:` into a cluster map. It does not come
/// through the values chain at all — `readChannelStages` in
/// `hostyour-manager/server/domains/inventory/channel-stages.ts` reads `platform/values-common.yaml`
/// itself, off the trunk, through the Controller's `PlatformRepo` git port.
///
/// **WHAT A SECOND STATEMENT COSTS.** Two statements of the ceiling do not disagree on the day the
/// second one is written. They disagree on the day one of them is edited, and from then on one
/// writing point admits a stage the other refuses. The direction that matters is the permissive
/// one: an `alpha` release reaching `prod` is gated, written, deployed and reported as an ordinary
/// release, because every side did exactly what it was told. Nothing fails and nothing is logged.
///
/// **THE CHANNELS AND THE STAGES ARE READ, NEVER LISTED HERE.** A list of channel names written
/// into this library would be a second statement of half the table, standing inside the guard that
/// exists to refuse second statements. So [channelCeilingIn] reads the table out of the values file
/// the chain loads it from, and the words the scan looks for are that table's own keys and values.
///
/// **WHAT COUNTS AS A STATEMENT.** A line naming a channel of the table AND a stage of the table
/// states the ceiling. The stage is read from the line itself or from the lines belonging to it, and
/// "belonging to it" is two things: every line indented deeper, and — where the line is a mapping
/// key — the block-sequence items standing at the key's OWN column. Both spellings stand in this
/// tree's YAML: `- dev` under `alpha:` is that key's value whether it is indented deeper or written
/// at the key's own indentation, and a reader that broke the run at the first line indented no
/// deeper would end before a single stage of the second spelling was read.
///
/// The table written the other way round is read as well: a mapping key naming a STAGE, with the
/// channels standing in its block (`dev:` over `- alpha`). Both readings are exercised over planted
/// duplicates in `channel_table_single_test.dart`, spelling by spelling — flow mapping, block
/// sequence at the key's column, block sequence indented deeper, the whole table on one line, a
/// multi-line flow sequence, a shell `case` arm, a JSON object, a Markdown table row.
///
/// **WHAT IT DOES NOT REACH.** Six things, and a finding it makes that is not a duplicate.
/// It does not read this `checks` package, whose fixtures state the table on purpose and which
/// nothing on a cluster reads. It does not read a restatement written in words the table does not
/// use — "alpha never leaves development" names no stage of the table. It does not read a channel
/// and its stages spelled in a case the table does not use, because the words are matched exactly as
/// the table spells them. It does not read the Controller's own reader, which is another
/// repository's file. It does not read THE FILE THE TABLE IS STATED IN — a second table appended to
/// `platform/values-common.yaml` itself leaves this green, and that file is the likeliest place one
/// appears during a migration. And it does not read YAML's explicit-key spelling (`? alpha` /
/// `: [dev]`), which `package:yaml` loads to the identical table; no file in this tree uses it. In the other direction, a channel word standing over a stage word for an
/// unrelated reason — a tenant named `stable` with `namespace: dev` under it — is reported as a
/// statement, because the scan reads words and not meaning; that is a red gate to answer, not a
/// silent pass.
library;

import 'package:yaml/yaml.dart';

/// The key the platform values chain carries the channel ceiling under, inside `global`.
const String channelStagesKey = 'channelStages';

/// The stages each channel may reach, out of the `global` map of [values], under
/// [channelStagesKey].
///
/// Empty where [values] carries no such table. Every caller must treat that as a refusal and not as
/// "no channel may reach anything": an audit driven by an empty table looks for no word, finds
/// nothing, and reads exactly like a tree that states the ceiling once.
Map<String, List<String>> channelCeilingIn(String values) {
  final Object? loaded = loadYaml(values);
  if (loaded is! Map) {
    return const <String, List<String>>{};
  }
  final Object? global = loaded['global'];
  if (global is! Map) {
    return const <String, List<String>>{};
  }
  final Object? table = global[channelStagesKey];
  if (table is! Map) {
    return const <String, List<String>>{};
  }
  final Map<String, List<String>> ceiling = <String, List<String>>{};
  for (final Object? channel in table.keys) {
    final Object? stages = table[channel];
    if (channel is String && stages is List) {
      ceiling[channel] = <String>[
        for (final Object? stage in stages)
          if (stage is String) stage,
      ];
    }
  }
  return ceiling;
}

/// One place that states which stages a channel may reach.
final class CeilingStatement {
  /// Records the statement standing at [line] of [where], reading [text].
  const CeilingStatement({
    required this.where,
    required this.line,
    required this.text,
    required this.channels,
    required this.stages,
  });

  /// The file it stands in, as the tree names it.
  final String where;

  /// The line it opens on, counted from one, so a finding names a place to open.
  final int line;

  /// The opening line itself, trimmed — what was read, beside where it was read.
  final String text;

  /// The channels of the table the statement names.
  final Set<String> channels;

  /// The stages of the table the statement names.
  final Set<String> stages;
}

/// A statement of the ceiling standing somewhere other than the file that states it.
final class SecondCeiling {
  /// Records that [statement] states the ceiling, which [statedIn] already states.
  const SecondCeiling({required this.statement, required this.statedIn});

  /// The statement that should not exist.
  final CeilingStatement statement;

  /// The file the ceiling is stated in, and that every enforcing point reads — two of them through
  /// the values chain, the cluster release by reading this file itself off the trunk.
  final String statedIn;

  /// The one line a refusal says about it.
  @override
  String toString() =>
      '${statement.where}:${statement.line} states which stages '
      '${_listed(statement.channels)} may reach (${_listed(statement.stages)}) — "${statement.text}"'
      '. The ceiling is stated in $statedIn: gate-stage and bump read it from there through the '
      'values chain as CHANNEL_STAGES, and a cluster release reads that same file off the trunk '
      '(readChannelStages, hostyour-manager). A second statement drifts the day either one is '
      'edited, and a writing point that admits a stage the others refuse reports nothing at all';
}

/// Every statement of the ceiling [text] carries, where [text] is the content of the file at
/// [where] and [channels] and [stages] are the words the table itself is made of.
///
/// The scan is over lines rather than over a parse because the places this repository could restate
/// the ceiling are not all YAML documents: one would be a Helm template that becomes YAML only when
/// rendered, one a shell script inside a Tekton step's block scalar, one a CEL expression inside a
/// trigger. A parse would reach the first kind and refuse the other two.
List<CeilingStatement> ceilingStatementsIn({
  required String where,
  required String text,
  required Set<String> channels,
  required Set<String> stages,
}) {
  final Map<String, RegExp> channelWords = _wordPatterns(channels);
  final Map<String, RegExp> stageWords = _wordPatterns(stages);
  final List<String> lines = text.split('\n');
  final List<CeilingStatement> found = <CeilingStatement>[];
  for (int index = 0; index < lines.length; index++) {
    final String line = _withoutReturn(lines[index]);
    final Set<String> channelsHere = _wordsIn(line, channelWords);
    final Set<String> stagesHere = _wordsIn(line, stageWords);
    if (channelsHere.isEmpty && stagesHere.isEmpty) {
      continue;
    }
    final Set<String> channelsBelow = <String>{};
    final Set<String> stagesBelow = <String>{};
    for (final String below in _blockUnder(lines, index)) {
      channelsBelow.addAll(_wordsIn(below, channelWords));
      stagesBelow.addAll(_wordsIn(below, stageWords));
    }

    final Set<String> channels;
    final Set<String> stages;
    if (channelsHere.isNotEmpty) {
      channels = channelsHere;
      stages = <String>{...stagesHere, ...stagesBelow};
    } else if (_opensAMappingKey(line)) {
      channels = channelsBelow;
      stages = stagesHere;
    } else {
      continue;
    }
    if (channels.isEmpty || stages.isEmpty) {
      continue;
    }
    found.add(
      CeilingStatement(
        where: where,
        line: index + 1,
        text: line.trim(),
        channels: channels,
        stages: stages,
      ),
    );
  }
  return found;
}

/// Every statement of the ceiling in [files] that does not stand in [statedIn].
///
/// [files] is keyed by the path a finding names. [statedIn] is the one file the table is stated in;
/// that the table is still stated THERE is the caller's to assert, because an audit over a tree
/// that states the ceiling nowhere at all answers empty just as a correct tree does.
List<SecondCeiling> auditChannelTableSingle({
  required Map<String, String> files,
  required String statedIn,
  required Set<String> channels,
  required Set<String> stages,
}) => <SecondCeiling>[
  for (final MapEntry<String, String> each in files.entries)
    if (each.key != statedIn)
      for (final CeilingStatement statement in ceilingStatementsIn(
        where: each.key,
        text: each.value,
        channels: channels,
        stages: stages,
      ))
        SecondCeiling(statement: statement, statedIn: statedIn),
];

/// The lines below [index] that belong to the line at [index]: every line indented deeper than it,
/// and — where it is a mapping key — the block-sequence items standing at the key's OWN column.
///
/// The second half is what YAML permits and what this tree writes both ways: `- dev` under `alpha:`
/// is that key's value at the key's indentation, so a run broken at the first line indented no
/// deeper ends before a single stage is read. A line at the key's column that is not a sequence item
/// is the next sibling key and does end the run.
///
/// A blank line does not end the run: a table written with its channels spaced apart is the same
/// table. Indentation is counted in characters of leading whitespace, which is what a YAML block and
/// a shell heredoc both agree on.
List<String> _blockUnder(List<String> lines, int index) {
  final String opening = _withoutReturn(lines[index]);
  final int indent = _indentOf(opening);
  final bool key = _opensAMappingKey(opening);
  final List<String> block = <String>[];
  for (int below = index + 1; below < lines.length; below++) {
    final String line = _withoutReturn(lines[below]);
    if (line.trim().isEmpty) {
      continue;
    }
    final int deep = _indentOf(line);
    if (deep > indent || (deep == indent && key && _isSequenceItem(line))) {
      block.add(line);
      continue;
    }
    break;
  }
  return block;
}

/// The characters of leading whitespace [line] carries.
int _indentOf(String line) => line.length - line.trimLeft().length;

/// Whether [line] states a mapping key whose value stands below it — `alpha:`, with or without a
/// trailing comment.
bool _opensAMappingKey(String line) => _withoutComment(line).trimRight().endsWith(':');

/// Whether [line] is a block-sequence item — `- dev`, or the bare `-` that carries a nested node.
bool _isSequenceItem(String line) {
  final String content = line.trimLeft();
  return content == '-' || content.startsWith('- ');
}

/// [line] up to the `#` that opens a YAML comment — one at the line start or after whitespace, so a
/// `#` inside a word is not read as one.
String _withoutComment(String line) {
  for (int at = 0; at < line.length; at++) {
    if (line[at] != '#') {
      continue;
    }
    if (at == 0 || line[at - 1] == ' ' || line[at - 1] == '\t') {
      return line.substring(0, at);
    }
  }
  return line;
}

/// Each of [words] as a pattern matching it on its own, so a channel named `alpha` is found where
/// it stands as a word and not inside `v1alpha1`.
Map<String, RegExp> _wordPatterns(Set<String> words) => <String, RegExp>{
  for (final String word in words) word: RegExp(r'\b' + RegExp.escape(word) + r'\b'),
};

/// Which of [patterns] [line] names.
Set<String> _wordsIn(String line, Map<String, RegExp> patterns) => <String>{
  for (final MapEntry<String, RegExp> each in patterns.entries)
    if (each.value.hasMatch(line)) each.key,
};

/// [line] without the carriage return a checkout on Windows leaves at its end.
String _withoutReturn(String line) =>
    line.endsWith('\r') ? line.substring(0, line.length - 1) : line;

/// [values] as a refusal spells a set out, sorted so the sentence does not move with a hash order.
String _listed(Set<String> values) {
  final List<String> sorted = values.toList()..sort();
  return sorted.isEmpty ? 'nothing' : sorted.map((String each) => '"$each"').join(', ');
}
