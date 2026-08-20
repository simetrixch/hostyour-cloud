/// client-flutter-pin — the Flutter version this repository decides, held against the one the
/// client is built with, on the side where the raise is made.
///
/// **WHY THE NUMBER IS WRITTEN TWICE.** `platform/versions.yaml` decides every component's version,
/// and the Flutter the client is built with stands in it under [flutterPinPath]. The client writes
/// it a second time because its `tool/version_guard.dart` refuses every SDK but the one its own gate
/// names, and that repository is cloned on its own by anybody building it — a pin it could only
/// learn from another checkout would leave that guard with nothing to read. Two spellings of one
/// version is the shape, and what is needed is a reader that says the day they disagree.
///
/// **WHY A SECOND READER, WHEN THE CLIENT ALREADY HAS ONE.** The client's `tool/flutter_pin.dart`
/// holds the same two numbers against each other and refuses the client's gate on a drift. It runs
/// in the client. A raise is made HERE — this file is where a version is decided and the client's is
/// a site of it — so the person who causes the drift is the one person that guard does not answer:
/// they edit [platformVersions], run this gate, and it says nothing about the tree their edit just
/// left behind. This check is that guard on the side the raise happens.
///
/// **THE CLIENT'S COORDINATES ARE READ, NEVER RESTATED.** Which file of the client carries the
/// spelling is the client's to say, and it says it: `tool/flutter_pin.dart` — [clientPinReader],
/// which is also what makes a checkout the client — states it as [clientPinFileConstant]. So a
/// client that moves its spelling is followed rather than reported against a path this file
/// remembers. The ONE thing restated is the constant's name, [clientPinConstant], because the client
/// states that in no constant of its own; the client's release workflow reads the same literal form
/// out of the same file with `sed` (`.github/workflows/release.yml`), so a rename of it turns two
/// readers red rather than leaving either silent.
///
/// **What is judged.** The value [platformVersions] states at [flutterPinPath], against the string
/// constant [clientPinConstant] of the file the client's [clientPinReader] names.
///
/// **WHAT IT DOES NOT REACH, each with the reason it is not judged.**
///
///   * Whether anything WRITES the client's spelling. Nothing does: the `toolchains.flutter` entry
///     of [platformVersions] carries no `stamps:` site, so both numbers are typed by a person and
///     this check reports the day they type one of them. What a stamp of that site is waiting on is
///     stated at the entry itself. Catching a drift is weaker than not being able to make one, and
///     this is the catching half.
///   * Which Flutter the machine that builds the client actually has. The client's own
///     `tool/version_guard.dart` refuses every SDK but the one named in the file read here, on the
///     machine where it matters; nothing readable from this tree says what is installed anywhere.
///   * Whether the decided version exists upstream, or is the newest. The `versions-upstream`
///     program reports every pin against its upstream, and this entry declares none, because no
///     kind of that grammar can ask the channel Flutter publishes to — the reason stands at the
///     entry.
///   * Any other toolchain. `toolchains.flutter` is the one entry of that group with a second
///     spelling in the client; a toolchain added beside it is spelled nowhere this reads and passes
///     here in silence.
///   * Whether the client's own gate still holds the pin at all. That `tool/flutter_pin.dart` is
///     there is what the search for the client tree reads, and what it DOES is judged by the
///     client's own counter-probes, in the client.
library;

import 'package:yaml/yaml.dart';

import 'installation_tree.dart';

/// Where this repository decides every component's version, relative to its root.
const String platformVersions = 'platform/versions.yaml';

/// The keys the Flutter pin stands under in [platformVersions].
const List<String> flutterPinPath = <String>['toolchains', 'flutter', 'version'];

/// The client's own name for the file of the client that carries its spelling of the pin.
///
/// Read out of [clientPinReader] rather than written here, so the path is the client's statement and
/// not this repository's memory of it.
const String clientPinFileConstant = 'pinnedIn';

/// The constant that carries the client's spelling, in the file [clientPinFileConstant] names.
const String clientPinConstant = 'flutterVersion';

/// One way the two spellings of the Flutter version are not one version.
final class PinFinding {
  /// Names the file at [where] and what is wrong with it, [because].
  const PinFinding({required this.where, required this.because});

  /// The file somebody has to open.
  final String where;

  /// What is wrong, in the words whoever raised the version reads.
  final String because;

  /// The one line a refusal says about it.
  @override
  String toString() => '$where $because';
}

/// The Flutter version [versions] decides, or null where it decides none as text.
///
/// Null for a value that is not text as well as for one that is absent: the grammar of that file
/// quotes every version because YAML reads an unquoted 3.47 as a number that has lost its trailing
/// zero, and a pin read as a number is a pin nothing can hold a string against.
String? flutterPinIn(String versions) {
  Object? node = loadYaml(versions);
  for (final String key in flutterPinPath) {
    if (node is! YamlMap) {
      return null;
    }
    node = node[key];
  }
  return node is String ? node : null;
}

/// The value of the top-level `const String` [name] in the Dart [source], or null where it states
/// none.
///
/// The declaration is required to begin at column zero, and that is what keeps a doc comment naming
/// the constant, or a local of the same name inside a function, from answering as the declaration.
/// The whole statement stands on one line in both files this reads, but that is what those files
/// hold rather than what is asked of them: a value carried onto a second line is read the same way.
String? dartStringConstantIn(String source, String name) {
  final RegExpMatch? found = RegExp(
    '^const String $name\\s*=\\s*([\'"])(.*?)\\1\\s*;',
    multiLine: true,
  ).firstMatch(source);
  return found?.group(2);
}

/// Every way the version [decided] by [platformVersions] and the one the client is built with are
/// not one version.
///
/// [pinFile] is the file of the client [clientPinReader] names as its own, and [spelled] is the
/// [clientPinConstant] standing in it — null where either states none, which is a refusal and never
/// a pass: a comparison that could read only one side reports exactly what a tree with nothing wrong
/// reports.
List<PinFinding> auditClientFlutterPin({
  required String? decided,
  required String? pinFile,
  required String? spelled,
}) {
  final String key = flutterPinPath.join('.');
  final List<PinFinding> found = <PinFinding>[];
  if (decided == null) {
    found.add(
      PinFinding(
        where: platformVersions,
        because:
            'states no "$key" as text — this is where the Flutter the client is built with is '
            'decided, and a version decided nowhere is one the client can spell freely',
      ),
    );
  }
  if (pinFile == null) {
    found.add(
      PinFinding(
        where: clientPinReader,
        because:
            'of the client states no "$clientPinFileConstant" — that constant is how the client '
            'says which of its files carries its spelling of "$key", and without it there is no '
            'second side to read',
      ),
    );
  } else if (spelled == null) {
    found.add(
      PinFinding(
        where: pinFile,
        because:
            'is the file the client\'s $clientPinReader names as carrying its pin, and it states no '
            'top-level "const String $clientPinConstant" — either the constant was renamed or the '
            'spelling moved, and this side was left reading nothing',
      ),
    );
  } else if (decided != null && decided != spelled) {
    found.add(
      PinFinding(
        where: pinFile,
        because:
            'of the client pins Flutter $spelled and $platformVersions decides "$key" Flutter '
            '$decided — the two spellings of one version have drifted, and $platformVersions is '
            'the one that decides, so raise the client\'s to $decided and install that SDK',
      ),
    );
  }
  return found;
}
