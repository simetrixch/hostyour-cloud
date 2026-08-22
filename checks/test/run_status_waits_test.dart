import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// run-status-waits — over the real trees, and over planted rows.
///
/// **Why both sides are read and neither may be missing.** The words a program waits for are written
/// in the installation's repository; the statuses a run can hold, and which of them a run comes to
/// rest at, are decided in the Controller's. Neither repository can see the other, so the suite
/// refuses over a tree it cannot find rather than passing because it found nothing to compare.
///
/// **Why nothing here restates the Controller's vocabulary.** A list of statuses written into this
/// suite would be a second spelling of `RUN_STATUS`, and a status renamed on the Controller side
/// would then go on passing here. Every word this suite holds a row against comes out of the
/// Controller tree, and a source stating none of them is a refusal rather than an empty answer.
void main() {
  group('the trees as they stand', () {
    test('every run status an installation program waits for is one a run rests at', () {
      final Directory controller = controllerRoot();
      final String runRoute = runReadRouteIn(
        File('${controller.path}/$controllerRunRoute').readAsStringSync(),
      );
      final List<String> declared = runStatusesIn(
        File('${controller.path}/$controllerRunStates').readAsStringSync(),
      );
      final Set<String> settled = settledRunStatusesIn(
        File('${controller.path}/$controllerRunRest').readAsStringSync(),
      );

      // The two reads have to land on ONE vocabulary. A predicate naming a word the enum does not
      // declare means one of the two was read off a source that had moved, and every row would then
      // be held against a set nobody wrote.
      expect(
        settled.difference(declared.toSet()),
        isEmpty,
        reason:
            '$controllerRunRest names statuses $controllerRunStates does not declare, so the two '
            'reads are not looking at the same vocabulary',
      );

      final List<RunStatusWait> waits = _waitsOf(runRoute);
      expect(
        waits,
        isNotEmpty,
        reason:
            'no program of the installation waits on a run\'s status, so nothing was judged — a '
            'route renamed on the Controller side reads exactly like a tree with no such row',
      );

      expect(
        auditRunStatusWaits(
          waits: waits,
          declared: declared,
          settled: settled,
        ).map((RunStatusFinding each) => each.toString()),
        isEmpty,
      );
    });

    test('HOW MUCH IT COVERS: against a vocabulary nothing is in, every awaited word reports', () {
      // What this measures is not the vocabulary but the REACH: a row or a word the reader passed
      // over would be silent here too, and a check that judges half the rows reads exactly like one
      // that judges all of them and found nothing.
      final List<RunStatusWait> waits = _waitsOf(
        runReadRouteIn(File('${controllerRoot().path}/$controllerRunRoute').readAsStringSync()),
      );
      final int awaited = waits.fold(
        0,
        (int sum, RunStatusWait each) => sum + each.until.length + each.failing.length,
      );
      expect(awaited, greaterThan(0), reason: 'a check over nothing reads like a pass');

      expect(
        auditRunStatusWaits(
          waits: waits,
          declared: const <String>['nothing-a-row-writes'],
          settled: const <String>{'nothing-a-row-writes'},
        ),
        hasLength(awaited),
      );
    });
  });

  group('what it reads out of the Controller', () {
    test('the run-read route comes out of the Controller\'s own route declaration', () {
      expect(
        runReadRouteIn('app.get("/api/runs", x);\napp.get("/api/runs/:id", y);\n'),
        '/api/runs',
      );
    });

    test('a route with a segment after the identifier is not the one run is read from', () {
      expect(
        () => runReadRouteIn('app.get("/api/runs/:id/events", y);\n'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('0 routes reading one run'),
          ),
        ),
      );
    });

    test('the statuses are read out of the Controller\'s own list, across the line break', () {
      expect(
        runStatusesIn(
          'export const $runStatusConstant = ["planning", "planned",\n'
          '  "cancelled"] as const;\n',
        ),
        <String>['planning', 'planned', 'cancelled'],
      );
    });

    test('a source declaring no such list is a refusal, never an empty vocabulary', () {
      expect(
        () => runStatusesIn('export const SOMETHING_ELSE = ["planned"] as const;\n'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains(runStatusConstant),
          ),
        ),
      );
    });

    test('the resting statuses are read out of the Controller\'s own predicate', () {
      expect(
        settledRunStatusesIn(
          'export const $settledRunPredicate = (s: RunStatus): boolean =>\n'
          '  s === "planned" || s === "failed";\n',
        ),
        <String>{'planned', 'failed'},
      );
    });

    test('a source stating no such predicate is a refusal, never an empty set', () {
      expect(
        () => settledRunStatusesIn('export const isTerminalRun = (s: RunStatus) => s === "x";\n'),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains(settledRunPredicate),
          ),
        ),
      );
    });
  });

  group('which rows are the subject', () {
    List<RunStatusWait> read(String document) => runStatusWaitsIn(
      program: 'planted.yaml',
      document: loadYaml(document),
      runRoute: '/api/runs',
    );

    test('a wait on one run\'s status is one', () {
      final List<RunStatusWait> found = read('''
steps:
  - step: wait_for_http_field
    waiting_for: the run to finish planning
    url: <controller-url>/api/runs/<run-id>
    field: status
    until: [planned]
    failing: [failed, cancelled]
''');
      expect(found, hasLength(1));
      expect(found.single.waitingFor, 'the run to finish planning');
      expect(found.single.until, <String>['planned']);
      expect(found.single.failing, <String>['failed', 'cancelled']);
    });

    test(
      'THE INNOCENT NEIGHBOUR: a wait_for_http_field that watches something which is not a run',
      () {
        expect(
          read('''
steps:
  - step: wait_for_http_field
    waiting_for: the controller to answer
    url: <controller-url>/api/health
    field: status
    until: [approved]
'''),
          isEmpty,
        );
      },
    );

    test('a wait on a run\'s events stream is not one either', () {
      expect(
        read('''
steps:
  - step: wait_for_http_field
    waiting_for: the run to say something
    url: <controller-url>/api/runs/<run-id>/events
    field: status
    until: [running]
'''),
        isEmpty,
      );
    });

    test('a wait on another field of the same address is not one', () {
      expect(
        read('''
steps:
  - step: wait_for_http_field
    waiting_for: the run to carry a plan hash
    url: <controller-url>/api/runs/<run-id>
    field: plan.planHash
    until: [anything]
'''),
        isEmpty,
      );
    });

    test('a step of another kind asking the same address is not one', () {
      expect(
        read('''
steps:
  - step: exchange_http_field
    method: POST
    url: <controller-url>/api/runs/<run-id>/approve
    field: ok
'''),
        isEmpty,
      );
    });
  });

  group('what a word is held against', () {
    final List<String> declared = runStatusesIn(
      File('${controllerRoot().path}/$controllerRunStates').readAsStringSync(),
    );
    final Set<String> settled = settledRunStatusesIn(
      File('${controllerRoot().path}/$controllerRunRest').readAsStringSync(),
    );

    List<RunStatusFinding> judge({
      List<String> until = const <String>[],
      List<String> failing = const <String>[],
    }) => auditRunStatusWaits(
      waits: <RunStatusWait>[
        RunStatusWait(
          program: 'onboard-manager.yaml',
          waitingFor: 'the run that onboards this controller to finish planning',
          until: until,
          failing: failing,
        ),
      ],
      declared: declared,
      settled: settled,
    );

    test('THE INNOCENT NEIGHBOUR: the rows as onboard-manager.yaml writes them are nothing', () {
      expect(judge(until: <String>['planned'], failing: <String>['failed', 'cancelled']), isEmpty);
      expect(
        judge(until: <String>['succeeded'], failing: <String>['failed', 'cancelled']),
        isEmpty,
      );
    });

    test('a word no RUN_STATUS holds is reported, naming the program, the row and the word', () {
      expect(
        judge(until: <String>['planed']).map((RunStatusFinding each) => each.toString()).single,
        allOf(
          startsWith(
            'onboard-manager.yaml, waiting for "the run that onboards this controller to finish '
            'planning", names "planed" in until: —',
          ),
          contains('is no status the Controller declares'),
          contains(controllerRunStates),
        ),
      );
    });

    test(
      'THE DEFECT THIS WAS BUILT AFTER: a status that is in the enum and is never rested at',
      () {
        expect(
          judge(until: <String>['approved']).map((RunStatusFinding each) => each.toString()).single,
          allOf(
            contains('names "approved" in until:'),
            contains('is a status a run passes THROUGH and never rests at'),
            contains(settledRunPredicate),
          ),
        );
      },
    );

    test('the failing list is held to exactly the same thing', () {
      expect(
        judge(failing: <String>['running', 'discarded']).map((RunStatusFinding each) => each.key),
        <String>['failing', 'failing'],
      );
    });

    test('a word that is not a string names no status either, and is reported as written', () {
      expect(
        runStatusWaitsIn(
          program: 'planted.yaml',
          document: loadYaml('''
steps:
  - step: wait_for_http_field
    waiting_for: the run
    url: <controller-url>/api/runs/<run-id>
    field: status
    until: [true]
'''),
          runRoute: '/api/runs',
        ).single.until,
        <String>['true'],
      );
    });
  });
}

/// Every row of every installation program that waits on a run's status, read over the real tree.
List<RunStatusWait> _waitsOf(String runRoute) {
  final Directory programs = Directory('${installationRoot().path}/$installationPrograms');
  return <RunStatusWait>[
    for (final File each in programs.listSync().whereType<File>().where(
      (File f) => f.path.endsWith('.yaml'),
    ))
      ...runStatusWaitsIn(
        program: each.uri.pathSegments.last,
        document: loadYaml(each.readAsStringSync()),
        runRoute: runRoute,
      ),
  ];
}
