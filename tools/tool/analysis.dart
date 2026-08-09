/// analysis — the analyzer and the formatter, over the gate package.
///
/// `dart analyze --fatal-infos --fatal-warnings` with this package's analysis_options is not a
/// style pass. strict-casts, strict-inference and strict-raw-types are on, so an implicit cast, an
/// inferred `dynamic` and a raw generic are each a type the author never chose and each stops the
/// run; unused_import, unused_local_variable and dead_code are raised to errors, which is the
/// no-leftovers rule of this project enforced by a tool rather than by a reviewer.
/// `dart format --set-exit-if-changed` is what keeps a diff about the change instead of about the
/// whitespace.
///
/// THIS IS THE ONE CHECK THAT CANNOT BE A `dart test`. A test runs inside the package it would
/// judge, so it is compiled by the very analysis it is meant to fail on: either the package
/// analyses, and the test has nothing to report, or it does not, and the test never starts.
/// Everything else lives under test/ and arrives with the suite.
///
/// IT NEEDS NO COUNTER-PROBE, and that is a property of what is left rather than an exemption.
/// Nothing here parses output; each tool's exit status IS the verdict, and there is nothing in
/// between that could stop matching and report a clean package.
///
/// `--output=none` writes nothing, so a red run leaves the tree exactly as it found it: a check
/// that repaired what it measures would be green the second time for having changed the thing it
/// judged.
///
///     dart run tool/analysis.dart
library;

import 'dart:io';

Future<void> main() async {
  final Directory package = File.fromUri(Platform.script).parent.parent;

  for (final List<String> argv in <List<String>>[
    <String>['analyze', '--fatal-infos', '--fatal-warnings'],
    <String>['format', '--output=none', '--set-exit-if-changed', '.'],
  ]) {
    stdout.writeln('analysis: dart ${argv.join(' ')}');
    final Process run = await Process.start(
      Platform.resolvedExecutable,
      argv,
      workingDirectory: package.path,
      mode: ProcessStartMode.inheritStdio,
    );
    final int status = await run.exitCode;
    if (status != 0) {
      stderr.writeln('analysis: FAIL — dart ${argv.first} exited $status');
      exit(1);
    }
  }

  stdout.writeln('analysis: OK — the gate package analyses clean and is formatted');
}
