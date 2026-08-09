import 'dart:io';

import 'helm.dart';

/// The [Helm] that runs the binary.
final class ProcessHelm implements Helm {
  /// A helm reached as the executable [executable] on PATH.
  const ProcessHelm({this.executable = 'helm'});

  /// What the tool is called.
  final String executable;

  @override
  bool get available {
    try {
      return Process.runSync(executable, const <String>['version', '--short']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  HelmOutcome addRepositories(Set<String> urls) {
    for (final String url in urls) {
      // The local name is a slug of the URL, because helm matches a dependency to a repository BY
      // URL and the name only decides what the cache directory is called. Derived rather than
      // listed, so a new upstream dependency cannot be the reason a render is reported broken.
      final HelmOutcome added = _run(<String>[
        'repo',
        'add',
        url.replaceAll(RegExp('[^A-Za-z0-9]'), '-'),
        url,
      ]);
      if (added is HelmRefused) {
        return added;
      }
    }
    return const HelmProduced('');
  }

  @override
  HelmOutcome vendorDependencies(String chartDirectory) {
    // `build` when the chart has a lock and `update` when it has not, and `update` again when the
    // lock is there but stale — a lock written against a Chart.yaml that has since been bumped
    // makes `build` refuse, and refusing is the right answer for a deployment and the wrong one
    // for a check that is about to render the bumped chart.
    final bool locked = File('$chartDirectory${Platform.pathSeparator}Chart.lock').existsSync();
    if (locked) {
      final HelmOutcome built = _run(const <String>[
        'dependency',
        'build',
      ], workingDirectory: chartDirectory);
      if (built is HelmProduced) {
        return built;
      }
    }
    return _run(const <String>['dependency', 'update'], workingDirectory: chartDirectory);
  }

  @override
  HelmOutcome render(ChartRender request) => _run(<String>[
    'template',
    request.releaseName,
    '.',
    '--namespace',
    request.namespace,
    for (final String file in request.valueFiles) ...<String>['-f', file],
    for (final MapEntry<String, String> value in request.values.entries) ...<String>[
      '--set',
      '${value.key}=${value.value}',
    ],
  ], workingDirectory: request.chartDirectory);

  HelmOutcome _run(List<String> arguments, {String? workingDirectory}) {
    final ProcessResult result;
    try {
      result = Process.runSync(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      );
    } on ProcessException catch (error) {
      return HelmRefused('$executable could not be started: ${error.message}');
    }
    final Object? out = result.stdout;
    final Object? failure = result.stderr;
    if (result.exitCode != 0) {
      return HelmRefused(_oneLine(failure is String ? failure : '$failure'));
    }
    return HelmProduced(out is String ? out : '');
  }

  /// helm writes a template failure over several lines with the whole values context in it, and a
  /// finding that carries all of it buries the twenty others beside it.
  static String _oneLine(String text) {
    final String flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 400 ? flat : '${flat.substring(0, 400)}…';
  }
}
