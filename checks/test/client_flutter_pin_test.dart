import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// client-flutter-pin — over the real trees, and over planted ones.
///
/// **What this is guarding.** `platform/versions.yaml` decides the Flutter the client is built with,
/// and the client writes that number a second time because its own `tool/version_guard.dart` refuses
/// every SDK but the one its gate names and that repository is cloned on its own. The client's
/// `tool/flutter_pin.dart` holds the two against each other IN THE CLIENT. A raise is made here, so
/// without this check the person who causes the drift is the one person no guard answers.
///
/// **Why the counter-probe raises the pin in the real declaration.** The drift this exists for is
/// somebody editing `toolchains.flutter.version` and committing, so the probe does exactly that to
/// the text of the real file, reads it back through the same reader the check uses, and holds it
/// against the client's real spelling. A fixture of the file's shape would prove the reader; only
/// the file itself proves the check would have caught the edit.
void main() {
  final Directory repository = Directory.current.parent;

  group('the trees as they stand', () {
    test('the client is built with the Flutter version this repository decides', () {
      final _BothSides read = _bothSides(repository);

      expect(
        auditClientFlutterPin(
          decided: read.decided,
          pinFile: read.pinFile,
          spelled: read.spelled,
        ).map((PinFinding each) => each.toString()),
        isEmpty,
      );
    });

    test('THE COUNTER-PROBE: a version raised here and not in the client turns this gate red', () {
      final _BothSides read = _bothSides(repository);
      final String raised = _raised(read.decided);
      final String edited = _flutterRaisedTo(raised, read.versions, was: read.decided);

      expect(
        flutterPinIn(edited),
        raised,
        reason:
            'the probe did not raise the pin in the declaration it edited, so what follows would '
            'hold the client against the version it already agrees with',
      );

      final List<PinFinding> found = auditClientFlutterPin(
        decided: flutterPinIn(edited),
        pinFile: read.pinFile,
        spelled: read.spelled,
      );

      expect(found, hasLength(1));
      expect(found.single.where, read.pinFile);
      expect(found.single.toString(), contains(raised));
      expect(found.single.toString(), contains(read.spelled));
      expect(found.single.toString(), contains(read.pinFile));
    });

    test('a version raised in the client and not here is reported the same way', () {
      final _BothSides read = _bothSides(repository);

      // Drifted by construction — the client's real spelling against a raise of itself — rather
      // than by raising one of two values the tree states. A probe built on the tree agreeing with
      // itself reports nothing on the day it does not, which is the day it is read.
      final List<PinFinding> found = auditClientFlutterPin(
        decided: read.spelled,
        pinFile: read.pinFile,
        spelled: _raised(read.spelled),
      );

      expect(found, hasLength(1));
      // The direction the refusal states is not symmetric even though the detection is: this
      // repository decides, and the client's spelling is a site of that decision.
      expect(found.single.toString(), contains('raise the client\'s to ${read.spelled}'));
    });
  });

  group('what the declaration states', () {
    test('the pin is read under the keys the toolchains group states it at', () {
      expect(
        flutterPinIn('''
toolchains:
  flutter:
    version: "3.47.0"
    note: |
      one line about it
'''),
        '3.47.0',
      );
    });

    test('a version of some other component is never answered as this one', () {
      expect(
        flutterPinIn('''
images:
  zot:
    version: "v2.1.18"
cliTools:
  argocd:
    version: "v3.4.5"
'''),
        isNull,
      );
      expect(flutterPinIn('toolchains:\n  dart:\n    version: "3.13.0"\n'), isNull);
    });

    test('an unquoted pin reads as nothing — YAML answers a number, and a number is not a pin', () {
      // 3.47 unquoted is a double, and 3.47.0 unquoted is not, so the quoting the grammar of the
      // file demands is what keeps this reader from answering a version that lost its last digits.
      expect(flutterPinIn('toolchains:\n  flutter:\n    version: 3.47\n'), isNull);
    });

    test('a declaration that is no mapping reads as nothing rather than throwing', () {
      expect(flutterPinIn('# nothing but a comment\n'), isNull);
      expect(flutterPinIn('- toolchains\n'), isNull);
    });
  });

  group('what a Dart constant says', () {
    test('both quotings of the same declaration are read', () {
      expect(
        dartStringConstantIn("const String flutterVersion = '3.47.0';\n", 'flutterVersion'),
        '3.47.0',
      );
      expect(
        dartStringConstantIn('const String flutterVersion = "3.47.0";\n', 'flutterVersion'),
        '3.47.0',
      );
    });

    test('a doc comment naming the constant is not the declaration of it', () {
      expect(
        dartStringConstantIn(
          "/// [pinned] is `flutterVersion` of the gate — const String flutterVersion = 'x';\n",
          'flutterVersion',
        ),
        isNull,
      );
    });

    test('a constant standing inside something is not the top-level one', () {
      expect(
        dartStringConstantIn("  const String flutterVersion = '9.9.9';\n", 'flutterVersion'),
        isNull,
      );
    });

    test('THE INNOCENT NEIGHBOUR: a constant whose name merely begins with the one asked for', () {
      expect(
        dartStringConstantIn("const String flutterVersionWas = '3.46.0';\n", 'flutterVersion'),
        isNull,
      );
    });

    test('a file stating no such constant reads as nothing, which the audit refuses over', () {
      expect(dartStringConstantIn('const int answer = 42;\n', 'flutterVersion'), isNull);
    });
  });

  group('what the audit says', () {
    test('two spellings of one version are nothing to report', () {
      expect(
        auditClientFlutterPin(decided: '3.47.0', pinFile: 'tool/ci.dart', spelled: '3.47.0'),
        isEmpty,
      );
    });

    test('a declaration stating no pin is a refusal and never a pass', () {
      final List<PinFinding> found = auditClientFlutterPin(
        decided: null,
        pinFile: 'tool/ci.dart',
        spelled: '3.47.0',
      );

      expect(found, hasLength(1));
      expect(found.single.where, platformVersions);
      expect(found.single.toString(), contains(flutterPinPath.join('.')));
    });

    test('a client naming no file for its pin is refused, and the reader is named', () {
      final List<PinFinding> found = auditClientFlutterPin(
        decided: '3.47.0',
        pinFile: null,
        spelled: null,
      );

      expect(found, hasLength(1));
      expect(found.single.where, clientPinReader);
      expect(found.single.toString(), contains(clientPinFileConstant));
    });

    test('a named file stating no constant is refused, and the file is named', () {
      final List<PinFinding> found = auditClientFlutterPin(
        decided: '3.47.0',
        pinFile: 'tool/ci.dart',
        spelled: null,
      );

      expect(found, hasLength(1));
      expect(found.single.where, 'tool/ci.dart');
      expect(found.single.toString(), contains(clientPinConstant));
    });

    test('both sides missing are both reported, so the fix is one edit and not two runs', () {
      expect(auditClientFlutterPin(decided: null, pinFile: null, spelled: null), hasLength(2));
    });
  });

  group('the client tree, planted', () {
    late Directory workspace;

    setUp(() {
      // Under the system temporary directory rather than beside the repository, so nothing the
      // search walks past belongs to this checkout.
      workspace = Directory.systemTemp.createTempSync('client-search');
      addTearDown(() => workspace.deleteSync(recursive: true));
    });

    Directory planted(String path) =>
        Directory('${workspace.path}/$path')..createSync(recursive: true);

    Directory clientAt(String path) {
      final Directory root = planted(path);
      File('${root.path}/$clientPinReader').createSync(recursive: true);
      return root;
    }

    test('a checkout standing beside the repository the suite runs in is found by its file', () {
      final Directory client = clientAt('checkout');

      expect(
        p.normalize(clientFoundFrom(planted('repository/checks')).path),
        p.normalize(client.path),
      );
    });

    test('a checkout one directory further out is found, where grouped checkouts put it', () {
      final Directory client = clientAt('group-b/checkout');

      expect(
        p.normalize(clientFoundFrom(planted('group-a/repository')).path),
        p.normalize(client.path),
      );
    });

    test('THE INNOCENT NEIGHBOUR: a tree carrying tool/ and not the client\'s reader', () {
      // The shape of this repository's own checks package, which carries tool/ci.dart. A search
      // keyed on the directory rather than on the file would answer with it.
      planted('repository/checks/tool');
      final Directory client = clientAt('group-b/checkout');

      expect(
        p.normalize(clientFoundFrom(planted('repository/checks')).path),
        p.normalize(client.path),
      );
    });

    test('two trees under the same directory are refused, and both are named', () {
      final Directory one = clientAt('group-b/checkout');
      final Directory other = clientAt('group-c/checkout');

      expect(
        () => clientFoundFrom(planted('group-a/repository')),
        throwsA(
          isA<StateError>()
              .having(
                (StateError refused) => refused.message,
                'message',
                contains(p.normalize(one.path)),
              )
              .having(
                (StateError refused) => refused.message,
                'message',
                contains(p.normalize(other.path)),
              )
              // Reading one of the two would be a choice nobody made, reported as a fact.
              .having((StateError refused) => refused.message, 'message', contains(clientVariable)),
        ),
      );
    });

    // What a search that finds NO client tree does is not probed here, and the suite beside this one
    // does not probe it for the installation either: the walk goes up to the root of the volume, so
    // the answer depends on every checkout the machine running it happens to carry. The refusal
    // itself is one sentence in installation_tree.dart, shared by all three kinds of tree.
  });
}

/// The two spellings as the two trees stand, with the declaration's text the probes edit.
typedef _BothSides = ({String versions, String decided, String pinFile, String spelled});

/// Both sides read where each is decided, with every side asserted present before anything is
/// judged against it.
///
/// A comparison driven by a side it could not read reports exactly what two trees with nothing wrong
/// report, which is the failure this whole suite exists to refuse.
_BothSides _bothSides(Directory repository) {
  final Directory client = clientRoot();
  final String versions = File('${repository.path}/$platformVersions').readAsStringSync();
  final String? decided = flutterPinIn(versions);
  expect(
    decided,
    isNotNull,
    reason:
        '$platformVersions states no "${flutterPinPath.join('.')}" as text — it was not read, and '
        'the client would be held against nothing',
  );

  final String? pinFile = dartStringConstantIn(
    File('${client.path}/$clientPinReader').readAsStringSync(),
    clientPinFileConstant,
  );
  expect(
    pinFile,
    isNotNull,
    reason:
        '$clientPinReader of the client states no "$clientPinFileConstant" — which of its files '
        'carries the pin was not read',
  );

  final String? spelled = dartStringConstantIn(
    File('${client.path}/$pinFile').readAsStringSync(),
    clientPinConstant,
  );
  expect(
    spelled,
    isNotNull,
    reason: '$pinFile of the client states no "const String $clientPinConstant" — it was not read',
  );

  return (versions: versions, decided: decided!, pinFile: pinFile!, spelled: spelled!);
}

/// [version] raised, so a probe drifts the two spellings with a version of the same shape.
String _raised(String version) {
  final List<String> parts = version.split('.');
  final int? last = int.tryParse(parts.last);
  if (last == null) {
    return '$version.1';
  }
  parts[parts.length - 1] = '${last + 1}';
  return parts.join('.');
}

/// [versions] with the Flutter pin written as [raised] in place of [was].
///
/// The edit is made below the `flutter:` key and nowhere else: the declaration pins several
/// components, and a replacement over the whole file would raise whichever of them happens to carry
/// the same number first and prove nothing about this one.
String _flutterRaisedTo(String raised, String versions, {required String was}) {
  final int at = versions.indexOf('\n  flutter:\n');
  expect(
    at,
    isNot(-1),
    reason:
        '$platformVersions holds no "flutter:" component of the toolchains group — the probe cannot '
        'raise a pin it cannot find, and the check above would be reading a key that moved',
  );
  return versions.substring(0, at) + versions.substring(at).replaceFirst('"$was"', '"$raised"');
}
