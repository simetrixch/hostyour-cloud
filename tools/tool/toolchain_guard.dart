/// The pins, applied to the toolchain the gate is about to start.
///
/// The pinned container this replaces made the pinned versions the only ones a check could meet:
/// the image carried one Dart and one helm, and nothing outside it was reachable from inside. On
/// the bare machine the pin is a REQUIREMENT instead of an installation, and this is what enforces
/// it — the run is refused before any check can answer under a toolchain the answer is not true
/// for, with the found and the expected version in the refusal.
///
/// TWO TOOLS ARE READ, BECAUSE TWO TOOLS DECIDE WHAT A CHECK ANSWERS. `dart pub get`, the analyzer
/// and the suite all run under the SDK the gate is itself running on — tool/ci.dart starts each of
/// them as `Platform.resolvedExecutable` — so reading `Platform.version` reads the version of
/// everything the run would use. helm is the other one: `ProcessHelm` starts it by name off the
/// PATH, and it is what turns every chart under apps/ into the manifests the render audit decides
/// about, so a helm that templates differently is a render audit answering about a different tree.
///
/// NOTHING ELSE IS READ. `git ls-files --full-name` is the only other program a check starts, no
/// pin in this repository names git, and its answer is the same on every version of it that has
/// the subcommand at all.
library;

import 'dart:io';

/// The bare version out of [platformVersion].
///
/// `Platform.version` answers the version first and the channel, the build date and the platform
/// after it — `3.12.2 (stable) (Tue Jun 9 01:11:39 2026 -0700) on "windows_x64"` — so the version
/// is everything before the first whitespace.
String dartVersionOf(String platformVersion) => platformVersion.trim().split(RegExp(r'\s')).first;

/// The version out of what [printed] carries, or null when it carries no version at all.
///
/// [printed] is what `helm version --template {{.Version}}` writes: the bare version and nothing
/// else. That form is read rather than `helm version`, which writes a Go struct literal with the
/// commit, the tree state, the Go version and the Kubernetes client version around it — four more
/// fields whose shape a helm release may change, each of which a parser would then have to survive.
String? helmVersionIn(String printed) {
  final String first = printed.trim().split(RegExp(r'\s')).first;
  return _bareVersion.hasMatch(first) ? first : null;
}

/// What `helm version --template {{.Version}}` writes, or the empty string when no helm could be
/// started.
///
/// An empty answer is not a pass anywhere: [toolchainRefusal] reads no version out of it and
/// refuses, which is what a machine without helm has to meet.
String whatHelmSaysItIs() {
  try {
    final ProcessResult result = Process.runSync('helm', const <String>[
      'version',
      '--template',
      '{{.Version}}',
    ], stdoutEncoding: systemEncoding);
    final Object? out = result.stdout;
    return result.exitCode == 0 && out is String ? out : '';
  } on ProcessException {
    return '';
  }
}

/// Why the gate must not run on this toolchain, or null when it is the pinned one.
///
/// [runningDart] is what `Platform.version` answers and [helmSaid] is what [whatHelmSaysItIs]
/// wrote; [pinnedDart] and [pinnedHelm] are the versions tool/ci.dart pins.
String? toolchainRefusal({
  required String runningDart,
  required String pinnedDart,
  required String helmSaid,
  required String pinnedHelm,
}) {
  final String dart = dartVersionOf(runningDart);
  if (dart != pinnedDart) {
    return 'this gate is running on Dart $dart, and the checks of this repository are pinned to '
        'Dart $pinnedDart — every step it starts is this same SDK, so put the pinned one on the '
        'PATH, or raise the pin in tool/ci.dart';
  }
  final String? helm = helmVersionIn(helmSaid);
  if (helm == null) {
    return 'no helm answered `helm version --template {{.Version}}` with a version, so nothing '
        'could be held against the pinned helm $pinnedHelm — every chart under apps/ is rendered '
        'through helm and judged by what comes out, and a run without it would report a tree it '
        'never opened; put helm on the PATH and run that command by hand to see what it says';
  }
  if (helm != pinnedHelm) {
    return 'this is helm $helm, and the charts of this repository are pinned to helm $pinnedHelm — '
        'a render is only as true as the helm that produced it, so install the pinned one, or '
        'raise the pin in tool/ci.dart';
  }
  return null;
}

/// What a version looks like, so an error message helm wrote on standard output is not read as one.
final RegExp _bareVersion = RegExp(r'^v?\d+\.\d+\.\d+');
