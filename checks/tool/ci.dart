/// The gate of this repository: the analyzer, the formatter and the checks, in that order.
///
/// ```
/// dart run tool/ci.dart
/// ```
///
/// **Why a chart repository has one at all.** What this repository holds is read by go templates
/// under `missingkey=error`, where one missing key does not fail one Application — it ends the whole
/// reconcile and none is created. A defect of that kind has to be found where it is committed, and
/// the only thing that can find it is something that reads these files.
///
/// It imports nothing but `dart:`, for the same reason every gate in this organisation does: the
/// gate is what resolves the tree, so its own program has to start on a fresh clone where no package
/// has been resolved.
library;

import 'dart:io';

Future<int> main() async {
  final Directory here = File.fromUri(Platform.script).parent.parent;

  stdout.writeln('########## resolving ##########');
  if (await _run('dart', <String>['pub', 'get'], here) != 0) {
    return _verdict('pub get');
  }

  stdout.writeln('########## analyzer ##########');
  if (await _run('dart', <String>['analyze', '--fatal-infos', '--fatal-warnings'], here) != 0) {
    return _verdict('analyze');
  }

  stdout.writeln('########## formatter ##########');
  if (await _run('dart', <String>['format', '--output=none', '--set-exit-if-changed', '.'], here) !=
      0) {
    return _verdict('format');
  }

  stdout.writeln('########## checks ##########');
  if (await _run('dart', <String>['test'], here) != 0) {
    return _verdict('test');
  }

  stdout.writeln('########## verdict ##########');
  stdout.writeln('ci: OK — every check green');
  return 0;
}

/// Runs [executable] with [arguments] in [directory], passing its output straight through.
Future<int> _run(String executable, List<String> arguments, Directory directory) async {
  final Process process = await Process.start(
    executable,
    arguments,
    workingDirectory: directory.path,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
  );
  return process.exitCode;
}

/// Says which step failed and answers non-zero, so nothing downstream reads a red run as green.
int _verdict(String step) {
  stdout.writeln('########## verdict ##########');
  stdout.writeln('ci: FAIL — $step');
  return 1;
}
