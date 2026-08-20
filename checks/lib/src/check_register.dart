/// check-register — every check of this package is exported, has a suite beside it, and states in
/// its own library doc comment what it does not reach.
///
/// **WHAT A REGISTER IS FOR, AND WHY THIS ONE IS CODE.** `dart test` discovers whatever stands under
/// `test/` and reports whether any of it failed. Delete a suite and nothing fails: the check is
/// simply not there, and the run prints that every check is green. That is worse than a missing test,
/// because a check and its counter-probe live in the same file — the thing that would have noticed
/// goes with the thing it was watching.
///
/// A prose register cannot close it, and this package had one until hostyour-cloud#65 removed it:
/// `checks/checks.yaml` named every check and the file that carried it, and `tool/ci.dart` never
/// opened it — conflict markers stood in it through a green run, and an entry commented out passed
/// the same way. A register nothing reads reports neither the check somebody deleted nor the one
/// somebody added.
///
/// **WHAT IS HELD, AND WHY EACH HALF IS NEEDED.** A check of this package is a library under
/// `lib/src/` whose library doc comment opens by naming it — `/// <check-name> — ...` — and the name
/// it states is its own file name with the underscores written as hyphens. Around that:
///
///   * every library under `lib/src/`, check or helper, is exported by
///     `lib/hostyour_cloud_checks.dart`. An unexported library is read by nothing outside this
///     package, and it is the export that makes the analyzer report the day the file is deleted.
///   * every check library has `test/<library>_test.dart` beside it, and every suite under `test/`
///     has a check library of the matching name. The first direction is the deleted suite; the
///     second is a suite whose subject is not a check this package declares.
///   * every check library states, under the words `WHAT IT DOES NOT REACH`, what a green run of it
///     says nothing about. What that paragraph holds is what a reader consults to decide whether the
///     gate covers their case, and a check that only reports finding nothing is read as a guarantee
///     it never gave.
///
/// **WHAT IS READ IS THE FILE SYSTEM, NOT `git ls-files`.** This one judges what `dart test`
/// discovers, and `dart test` discovers from disk — an untracked library is still a library the
/// suite would run.
///
/// Which of the two a check beside it reads follows from its subject rather than from a habit: one
/// that judges what a CLUSTER renders reads the tracked tree, because a cluster clones and an
/// untracked file is not in the clone. Five do — `app-manifest-keys`, `chart-paths`,
/// `channel-table-single`, `external-secret-keys` and `release-pin-tags`, each running
/// `git ls-files` in its own suite. The rest read the file system, as this one does.
///
/// **WHAT IT DOES NOT REACH.** It does not read what a check DOES: a library that names itself, is
/// exported, has a suite of one empty test and states what it does not reach passes here, and the
/// only thing that judges the check itself is the check's own counter-probes. It does not read the
/// truth of the paragraph either — the words `WHAT IT DOES NOT REACH` standing over a stale
/// paragraph pass exactly as the true one does, so what is held is that the paragraph is THERE, in
/// the file that goes when the check goes. It does not see a check whose library doc comment opens
/// with no name AND that has no suite: nothing distinguishes that file from a helper like
/// `installation_tree.dart`, which is a library of this package with no check of its own. And it does
/// not read a Dart file standing anywhere else in this package: `tool/ci.dart` and `bin_probe.dart`
/// are held by the analyzer and the formatter alone, and whether `tool/ci.dart` still runs the suite
/// at all is not readable from here.
library;

/// One place the checks package does not hold itself to its own shape.
final class RegisterFinding {
  /// Records that the file at [where] is wrong [because].
  const RegisterFinding({required this.where, required this.because});

  /// The file somebody has to open, as a path relative to this package.
  final String where;

  /// What is wrong with it, in the words whoever wrote it reads.
  final String because;

  /// The one line a refusal says about it.
  @override
  String toString() => '$where $because';
}

/// Where the check libraries of this package stand, relative to the package root.
const String checkLibraryDirectory = 'lib/src';

/// Where the suites of this package stand, relative to the package root.
const String checkTestDirectory = 'test';

/// The library every check library of this package is exported by, relative to the package root.
const String packageLibraryPath = 'lib/hostyour_cloud_checks.dart';

/// The words a check library states what a green run of it says nothing about under.
const String limitsHeading = 'WHAT IT DOES NOT REACH';

/// A library doc comment's first line, naming the check the library carries.
///
/// The name is written the way the tree names a check everywhere else — lower case words joined by
/// hyphens — and the em dash is what separates it from the sentence that follows, so a first line
/// that merely begins with a lower-case word names nothing.
final RegExp _namedCheck = RegExp(r'^/// ([a-z0-9]+(?:-[a-z0-9]+)*) — ');

/// The library doc comment of [source]: the run of `///` lines it opens with.
///
/// The run rather than every `///` line in the file, because what is being read is what the library
/// says about itself, not what its members say about themselves.
String libraryDocCommentIn(String source) {
  final List<String> lines = <String>[];
  for (final String line in source.split('\n')) {
    final String content = line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
    if (!content.startsWith('///')) {
      break;
    }
    lines.add(content);
  }
  return lines.join('\n');
}

/// The check [source] names in the first line of its library doc comment, or null where it names
/// none.
String? checkNameIn(String source) => _namedCheck.firstMatch(libraryDocCommentIn(source))?.group(1);

/// Whether the library doc comment of [source] states what the check does not reach.
bool statesLimitsIn(String source) => libraryDocCommentIn(source).contains(limitsHeading);

/// The check name a library standing at [path] must state, derived from the file name alone.
///
/// `lib/src/chart_paths.dart` carries `chart-paths`. Deriving it rather than reading it from a list
/// is what keeps the name from becoming a second statement: a file renamed without its doc comment
/// is reported, and there is no third place holding the pair.
String checkNameOf(String path) =>
    path.split('/').last.replaceAll('.dart', '').replaceAll('_', '-');

/// The suite a check library standing at [path] must have beside it.
String testPathOf(String path) =>
    '$checkTestDirectory/${path.split('/').last.replaceAll('.dart', '')}_test.dart';

/// The library a suite standing at [path] is the suite of.
String libraryPathOf(String path) =>
    '$checkLibraryDirectory/${path.split('/').last.replaceAll('_test.dart', '')}.dart';

/// The libraries [packageLibrary] exports, as paths relative to this package.
Set<String> exportedLibrariesIn(String packageLibrary) => <String>{
  for (final RegExpMatch each in RegExp(
    r"^\s*export\s+'([^']+)'\s*;",
    multiLine: true,
  ).allMatches(packageLibrary))
    'lib/${each.group(1)!}',
};

/// Every way the checks package does not hold itself to its own shape.
///
/// [libraries] is the source of every library under `lib/src/`, by the path it stands at. [tests] is
/// the path of every suite under `test/`. [packageLibrary] is the source of
/// [packageLibraryPath]. Every path is relative to the package root, so a finding names the file
/// somebody has to open.
List<RegisterFinding> auditCheckRegister({
  required Map<String, String> libraries,
  required Set<String> tests,
  required String packageLibrary,
}) {
  final Set<String> exported = exportedLibrariesIn(packageLibrary);
  final List<RegisterFinding> found = <RegisterFinding>[];

  for (final String path in libraries.keys.toList()..sort()) {
    final String source = libraries[path]!;
    if (!exported.contains(path)) {
      found.add(
        RegisterFinding(
          where: path,
          because:
              'is exported by no line of $packageLibraryPath — nothing outside this package reads '
              'it, and the day it is deleted the analyzer has no dangling export to report',
        ),
      );
    }
    final String? named = checkNameIn(source);
    if (named == null) {
      continue;
    }
    final String expected = checkNameOf(path);
    if (named != expected) {
      found.add(
        RegisterFinding(
          where: path,
          because:
              'opens by naming the check "$named", and the file it stands in names "$expected" — '
              'two names for one check is what a register drifts by',
        ),
      );
    }
    if (!tests.contains(testPathOf(path))) {
      found.add(
        RegisterFinding(
          where: path,
          because:
              'names the check "$named" and no ${testPathOf(path)} stands beside it — dart test '
              'discovers what is on disk, so a check with no suite runs nowhere and the gate '
              'reports every check green',
        ),
      );
    }
    if (!statesLimitsIn(source)) {
      found.add(
        RegisterFinding(
          where: path,
          because:
              'names the check "$named" and its library doc comment says "$limitsHeading" nowhere '
              '— a check that only reports finding nothing is read as a guarantee it never gave',
        ),
      );
    }
  }

  for (final String path in tests.toList()..sort()) {
    final String library = libraryPathOf(path);
    final String? source = libraries[library];
    if (source == null) {
      found.add(
        RegisterFinding(
          where: path,
          because:
              'is a suite and no $library stands under $checkLibraryDirectory — a suite whose '
              'subject is not a check this package declares',
        ),
      );
    } else if (checkNameIn(source) == null) {
      found.add(
        RegisterFinding(
          where: path,
          because:
              'is a suite and $library opens by naming no check — the first line of a check '
              "library's doc comment names it, and this one is read as a helper",
        ),
      );
    }
  }

  return found;
}
