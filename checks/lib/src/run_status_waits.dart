/// run-status-waits — every run status an installation program waits for is a status the
/// Controller's runs actually come to rest in.
///
/// **What a row like this is.** An installation program that asks the Controller to do something
/// gets back a run identifier and then WATCHES that run: a `wait_for_http_field` row asks
/// `GET <controller>/api/runs/<id>` every `interval_seconds`, reads the answer's `status`, and ends
/// the moment that value is one the row names in `until:` — or, where it is one the row names in
/// `failing:`, ends at once as a failure naming the state instead of sitting out the window in
/// front of a state that will not change again.
///
/// **The words in those two lists are the Controller's, and nothing held them.** They are
/// `RUN_STATUS` values, declared in the Controller's [controllerRunStates]. To the installation's
/// own check set they are free text: it holds the step kind and the declared arguments, and
/// `until:` is a list of strings. So a row could name a word no run ever answers with — a typo, or a
/// status somebody renamed on the Controller side — and every check of both trees stayed green
/// while the program waited out its whole window and reported a deadline.
///
/// **THE MEASURED DEFECT WAS SPELLED RIGHT.** `planned` was replaced with `approved` in the wait
/// that stands in front of the approve. `approved` IS a `RUN_STATUS` value, so membership alone
/// would have passed it, and the program would have waited five minutes for a state that arrives
/// only after the row below it has run. That is why this check holds a second thing, and it is the
/// one that catches that shape.
///
/// **A POLL CAN ONLY SEE A STATUS THE RUN IS STILL HOLDING.** The row asks at an interval and reads
/// what the run holds at that instant, so a status the run merely passes THROUGH is one the poll may
/// never see, however healthy the run. Which statuses a run comes to rest in is the Controller's own
/// decision and is read out of [controllerRunRest]: [settledRunPredicate] admits a SETTLED run to be
/// deleted and refuses an in-flight one, so the statuses it names are exactly the ones a run stops
/// at. `planning`, `approved` and `running` are not among them — a run leaves each of them on the
/// executor's own initiative, and `approved` is left the instant the approve returns.
///
/// **NEITHER SIDE IS RESTATED, ALL THREE ARE READ.** The status vocabulary, the resting statuses and
/// even the route that makes a row this check's subject come out of the Controller tree —
/// [runStatusesIn], [settledRunStatusesIn] and [runReadRouteIn]. A list written into this file would
/// be a second spelling of the Controller's, and the drift being watched for could then happen
/// inside the guard. Where a source states none of them the reader REFUSES: a check that quietly
/// stops recognising its subject reports every program green while judging nothing.
///
/// **WHAT IT DOES NOT REACH.**
///
///   * WHICH resting status this particular run can arrive at. A row waiting for `succeeded` on a
///     run that can only ever fail reads exactly like a correct one, because the answer needs the
///     status the run stands at when the row begins and what its kind does from there — neither of
///     which is readable off a row. What IS held is that the word names a status a run stops at.
///   * A resting status the row names in NEITHER list. A run that settles there sits until the
///     deadline, and this check cannot say it is missing: which settled statuses a given run can
///     reach is the same unreadable fact as above, so demanding all four would refuse the two
///     correct rows this tree already carries.
///   * `timeout_seconds` and `interval_seconds`. A window too short for the work reports a deadline
///     on a run that was going to arrive, and nothing here reads how long the work takes.
///   * Whether the run identifier a row fills its address with is the run an earlier row created.
///     The slot is read as a slot.
///   * A wait that reads a run's status from anywhere but the Controller's run-read route — a field
///     of some other answer, or a route this reader does not recognise. Such a row is not this
///     check's subject and is judged by nothing here.
///   * Whether the row is COMPLETE. A row that names no `until:` at all is refused where every
///     program is refused, by the installation's own check set over the step's declared arguments.
///     This one judges the words, not the shape of the row.
library;

import 'package:yaml/yaml.dart';

/// The step kind that watches an address until a field of its answer reaches a named value.
const String waitStep = 'wait_for_http_field';

/// The field of a run's answer that carries its status.
const String runStatusField = 'status';

/// Where the Controller declares every status a run can hold, relative to the Controller root.
const String controllerRunStates = 'shared/enums.ts';

/// The Controller's own name for that list.
const String runStatusConstant = 'RUN_STATUS';

/// Where the Controller decides which of those statuses a run has SETTLED in, relative to the
/// Controller root.
const String controllerRunRest = 'server/executor/transitions.ts';

/// The Controller's own predicate for a run that has settled.
///
/// It answers whether a run may be soft-deleted, and it is the Controller's single statement of the
/// split this check needs: a settled run is deletable, an in-flight one is refused and has to settle
/// first.
const String settledRunPredicate = 'isDeletableRun';

/// Where the Controller declares the route one run is read from, relative to the Controller root.
const String controllerRunRoute = 'server/domains/runs/api.ts';

/// One row of an installation program that waits on a run's status.
final class RunStatusWait {
  /// Records that [program] waits, for the reason it states as [waitingFor], until the run's status
  /// is one of [until], and gives up where it is one of [failing].
  const RunStatusWait({
    required this.program,
    required this.waitingFor,
    required this.until,
    required this.failing,
  });

  /// The program file the row stands in, as the caller names it.
  final String program;

  /// What the row says it is waiting for, which is how a finding names WHICH row of a program is
  /// meant — a program may watch the same run twice.
  final String waitingFor;

  /// The statuses that end the wait as arrived.
  final List<String> until;

  /// The statuses that end it at once as over and not arrived.
  final List<String> failing;

  @override
  String toString() => '$program waits for $waitingFor';
}

/// One status a row waits for that a run is not guaranteed to be seen holding, and why not.
final class RunStatusFinding {
  /// Records that [program]'s row [waitingFor] names [status] under [key], which is wrong
  /// [because].
  const RunStatusFinding({
    required this.program,
    required this.waitingFor,
    required this.key,
    required this.status,
    required this.because,
  });

  /// The program somebody has to open.
  final String program;

  /// What that row says it is waiting for.
  final String waitingFor;

  /// Which of the row's two lists the word stands in — `until` or `failing`.
  final String key;

  /// The word itself, exactly as the row writes it.
  final String status;

  /// What is wrong with it, in the words whoever wrote the row reads.
  final String because;

  /// The one line a refusal says about it.
  @override
  String toString() => '$program, waiting for "$waitingFor", names "$status" in $key: — $because';
}

/// The route the Controller reads ONE run from, as [apiSource] declares it — `/api/runs` for
/// `app.get("/api/runs/:id", ...)`.
///
/// Read rather than written out, because it is what decides which rows are this check's subject: a
/// route renamed on the Controller side would leave a check carrying the old path passing over every
/// row it exists for, and reporting that nothing is wrong. Where the source declares no such route,
/// or more than one, this throws: nothing recognisable is not the same answer as nothing wrong.
String runReadRouteIn(String apiSource) {
  final List<RegExpMatch> found = RegExp(
    r'app\.get\("([^"]*)/:\w+"',
  ).allMatches(apiSource).toList();
  if (found.length != 1) {
    throw StateError(
      '${found.length} routes reading one run by its identifier were read out of '
      '$controllerRunRoute, and exactly one is what makes a program row this check\'s subject — '
      'with none, every wait on a run reads like a row watching something else and this check '
      'judges nothing at all.',
    );
  }
  return found.single.group(1)!;
}

/// Every status the Controller declares a run can hold, in the order [enumsSource] states them.
///
/// Throws where the source declares none: an audit driven by an empty vocabulary admits every word
/// a program can write, which is the pass this check exists to refuse.
List<String> runStatusesIn(String enumsSource) {
  final RegExpMatch? declared = RegExp(
    'export const $runStatusConstant\\s*=\\s*\\[(.*?)\\]\\s*as const',
    dotAll: true,
  ).firstMatch(enumsSource);
  final List<String> statuses = declared == null ? const <String>[] : _quotedIn(declared.group(1)!);
  if (statuses.isEmpty) {
    throw StateError(
      '$controllerRunStates states no $runStatusConstant list — the statuses a run can hold were '
      'not read, and every word a program waits for would have been held against an empty '
      'vocabulary.',
    );
  }
  return statuses;
}

/// The statuses a run has SETTLED in, as [transitionsSource] states them in [settledRunPredicate].
///
/// Throws where the source states no such predicate, for the same reason [runStatusesIn] does: an
/// empty set of resting statuses would report every correct row as a defect, and a set read from
/// nothing is not a set.
Set<String> settledRunStatusesIn(String transitionsSource) {
  final RegExpMatch? declared = RegExp(
    'export const $settledRunPredicate\\b[^;]*;',
    dotAll: true,
  ).firstMatch(transitionsSource);
  final Set<String> settled = declared == null
      ? const <String>{}
      : _quotedIn(declared.group(0)!).toSet();
  if (settled.isEmpty) {
    throw StateError(
      '$controllerRunRest states no $settledRunPredicate naming the statuses a run has settled in '
      '— which of them a run comes to rest in was not read, and a wait could not be held to it.',
    );
  }
  return settled;
}

/// The double-quoted words of [source], in the order it writes them.
List<String> _quotedIn(String source) => <String>[
  for (final RegExpMatch each in RegExp('"([^"]*)"').allMatches(source)) each.group(1)!,
];

/// Every row of [document] that waits on a run's status, named by [program].
///
/// A row is one when its step kind is [waitStep], the field it reads is [runStatusField], and the
/// address it asks is the Controller's [runRoute] followed by the run's identifier and nothing more.
/// The last part is what keeps a wait on a run's EVENTS stream, or on any other answer with a
/// `status` field, out of this check's subject.
///
/// The rows are read as data and never as text: what makes a row this kind is the value of its
/// `step` key and the address it asks, not the words around it.
List<RunStatusWait> runStatusWaitsIn({
  required String program,
  required Object? document,
  required String runRoute,
}) {
  final List<RunStatusWait> found = <RunStatusWait>[];
  if (document is! YamlMap) {
    return found;
  }
  final Object? steps = document['steps'];
  if (steps is! YamlList) {
    return found;
  }
  for (final Object? row in steps) {
    if (row is! YamlMap || row['step'] != waitStep || row['field'] != runStatusField) {
      continue;
    }
    final Object? url = row['url'];
    if (url is! String || !_readsOneRun(url, runRoute)) {
      continue;
    }
    final Object? waitingFor = row['waiting_for'];
    found.add(
      RunStatusWait(
        program: program,
        waitingFor: waitingFor is String ? waitingFor : '<no waiting_for named>',
        until: _statusesIn(row['until']),
        failing: _statusesIn(row['failing']),
      ),
    );
  }
  return found;
}

/// Whether [url] asks [runRoute] for one run: the route, then one segment and nothing after it.
bool _readsOneRun(String url, String runRoute) {
  final int at = url.indexOf('$runRoute/');
  if (at < 0) {
    return false;
  }
  final String rest = url.substring(at + runRoute.length + 1);
  return rest.isNotEmpty && !rest.contains('/');
}

/// The words a row's `until:` or `failing:` list holds, printed as the row writes them.
///
/// Anything that is not a list holds no words, and a value that is not a string is carried as it
/// prints: it names no status either way, and the finding says which word was written.
List<String> _statusesIn(Object? node) =>
    node is YamlList ? <String>[for (final Object? each in node) '$each'] : const <String>[];

/// Every status the rows of [waits] wait for that a run is not guaranteed to be seen holding.
///
/// [declared] is the vocabulary the Controller states in [controllerRunStates], read by
/// [runStatusesIn]; [settled] is the part of it a run comes to rest in, read by
/// [settledRunStatusesIn] out of [controllerRunRest]. Both are read there rather than written here,
/// so a status renamed or removed on the Controller side turns this tree red instead of leaving a
/// program waiting for a word that no longer exists.
List<RunStatusFinding> auditRunStatusWaits({
  required List<RunStatusWait> waits,
  required List<String> declared,
  required Set<String> settled,
}) {
  final List<RunStatusFinding> found = <RunStatusFinding>[];
  for (final RunStatusWait wait in waits) {
    for (final MapEntry<String, List<String>> list in <String, List<String>>{
      'until': wait.until,
      'failing': wait.failing,
    }.entries) {
      for (final String status in list.value) {
        final String? because = _refusalOf(status, declared, settled);
        if (because == null) {
          continue;
        }
        found.add(
          RunStatusFinding(
            program: wait.program,
            waitingFor: wait.waitingFor,
            key: list.key,
            status: status,
            because: because,
          ),
        );
      }
    }
  }
  return found;
}

/// Why a run is not guaranteed to be seen holding [status], or null where it is.
///
/// The consequence differs by which list the word stands in, so both are stated rather than the
/// `until:` one alone. A wrong word in `until:` means the row never ends on its own; a wrong word in
/// `failing:` means the row ends normally on a healthy run and only sits out its window on the run
/// it was written to catch — which is the harder defect to notice, because the case that exposes it
/// is the case nobody rehearses.
String? _refusalOf(String status, List<String> declared, Set<String> settled) {
  if (!declared.contains(status)) {
    return 'is no status the Controller declares. $controllerRunStates states $runStatusConstant '
        'as ${declared.join(', ')}, and a run answers with one of those and nothing else — so no '
        'answer can ever match this word: in until: the row waits out its whole window and reports '
        'a deadline, and in failing: the row never recognises the failure it was written to catch';
  }
  if (!settled.contains(status)) {
    return 'is a status a run passes THROUGH and never rests at. $controllerRunRest states '
        '$settledRunPredicate over ${(settled.toList()..sort()).join(', ')}, which is the '
        'Controller\'s own split: a run standing at one of those has settled, and a run at any '
        'other is still in flight and is moved on by the executor itself. This row asks once every '
        'interval_seconds and reads what the run holds at that instant, so whether it ever sees '
        'this word is a matter of timing rather than of the run succeeding — a slow run may be '
        'caught holding it and a fast one may not, and which of the two happened is not readable '
        'off the result';
  }
  return null;
}
