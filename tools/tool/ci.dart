/// ci — the gate of this repository, on this machine.
///
/// Nothing runs in a hosted CI. This program IS the CI, and it is a standing rule of this project
/// rather than a workaround: the gate is the done-criterion for every step, so it has to run where
/// a person can read it, break into it and fix it in the same minute.
///
/// THE FIRST THING IT DOES IS REFUSE THE WRONG TOOLCHAIN. The pins below name the one Dart and the
/// one helm the checks are true against, and tool/toolchain_guard.dart reads what is actually on
/// this machine and refuses every other, naming what it found and what was expected. That is what
/// the pinned Linux container used to do by carrying exactly one of each: the pins stopped naming
/// an image and started naming a requirement.
///
/// WHAT THE CONTAINER ALSO GAVE, AND WHERE IT WENT. Line endings are their own check, and it runs
/// anywhere — tools/test/line_endings_test.dart reads .gitattributes back against the bytes in the
/// tree. Case-sensitive filenames were the one thing a Windows-only run really would have let
/// through, and they are now decided rather than assumed: tools/test/directive_case_test.dart holds
/// every Dart directive against the path git tracks, byte for byte.
///
/// IT IMPORTS NOTHING BUT dart:io AND tool/toolchain_guard.dart, WHICH IMPORTS NOTHING BUT dart:io,
/// and that is load-bearing. `dart pub get` is this gate's own first step, so the gate has to be
/// able to start on a fresh clone where nothing has been resolved yet — and a single `package:`
/// import here would make it unable to start until it had already run.
///
///     dart run tool/ci.dart    run every check
library;

import 'dart:io';

import 'toolchain_guard.dart';

/// THE PINS. Each was read from the source named beside it, on the date given. A version recalled
/// from memory is as old as whoever recalled it, which is why the source is part of the record.
///
/// These are the toolchain of the GATE and not of the platform: what a cluster of this platform
/// runs is decided in platform/versions.yaml, and tools/lib/src/pins/ audits that file.
const String dartVersion =
    '3.12.2'; // storage.googleapis.com/dart-archive/channels/stable/release/latest/VERSION — 2026-08-07
const String helmVersion = 'v4.2.3'; // api.github.com/repos/helm/helm/releases/latest — 2026-08-07

/// The package the checks live in and run from: tools/, found from where this script sits.
Directory get _package => File.fromUri(Platform.script).parent.parent;

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty) {
    stderr.writeln('ci: FAIL — unknown option ${arguments.first} (this gate takes no options)');
    exit(2);
  }

  final String? refusal = toolchainRefusal(
    runningDart: Platform.version,
    pinnedDart: dartVersion,
    helmSaid: whatHelmSaysItIs(),
    pinnedHelm: helmVersion,
  );
  if (refusal != null) {
    stderr.writeln('ci: FAIL — $refusal');
    exit(1);
  }

  final String package = _package.path;
  final List<String> failed = <String>[];

  // `pub get` first and on its own: nothing below can say anything true without a resolved package
  // config — the analyzer reports every import as unresolved and the failure reads as a package
  // full of defects.
  stdout.writeln('\n########## dart pub get ##########');
  if (await _run(<String>['pub', 'get'], workingDirectory: package) != 0) {
    stderr.writeln('ci: FAIL — pub get');
    exit(1);
  }

  stdout.writeln('\n########## dart run tool/analysis.dart ##########');
  if (await _run(<String>['run', 'tool/analysis.dart'], workingDirectory: package) != 0) {
    failed.add('analysis');
  }

  // The suite runs even after the analyzer went red, or one failure hides the rest and the next run
  // finds a second problem that was there all along.
  stdout.writeln('\n########## dart test ##########');
  if (await _run(<String>['test', '--reporter', 'expanded'], workingDirectory: package) != 0) {
    failed.add('test');
  }

  stdout.writeln('\n########## verdict ##########');
  if (failed.isNotEmpty) {
    stderr.writeln('ci: FAIL — ${failed.join(' ')}');
    exit(1);
  }
  stdout.writeln('ci: OK — every check green');
}

/// Runs `dart [argv]` in [workingDirectory], showing its output as it happens.
///
/// The SDK is [Platform.resolvedExecutable] and never the word `dart` on the PATH, so every step
/// runs under the SDK the guard above just read — a machine carrying a second Dart cannot check the
/// tree with one and report under the version of the other.
Future<int> _run(List<String> argv, {required String workingDirectory}) async {
  final Process process = await Process.start(
    Platform.resolvedExecutable,
    argv,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}
