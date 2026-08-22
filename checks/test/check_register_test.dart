import 'dart:io';

import 'package:hostyour_cloud_checks/hostyour_cloud_checks.dart';
import 'package:test/test.dart';

/// check-register — over the package as it stands, and over planted ones.
///
/// **Why the probes plant a whole package.** What this check judges is the shape of a package: which
/// libraries stand under `lib/src/`, which suites stand under `test/`, and what the package library
/// exports. A probe that planted one file would prove a reader finds a string; each probe below
/// plants a complete package of two libraries and one suite and changes exactly one thing about it.
void main() {
  /// Where [entity] stands, relative to the package root, written the way the register reads a path.
  ///
  /// A listing answers with the separator the platform uses and with the directory it was given
  /// already on the front, so the whole of the work is turning a backslash into a slash.
  String pathOf(FileSystemEntity entity) => entity.path.replaceAll(r'\', '/');

  group('the package as it stands', () {
    test('every check is exported, has a suite beside it, and states what it does not reach', () {
      // RECURSIVE, AND KEYED ON THE REAL PATH. A non-recursive listing sees only the top level, and
      // a file one directory down is then exempt from every rule below. Keying a recursive listing
      // on the file name is worse than that: lib/src/sub/chart_paths.dart and
      // lib/src/chart_paths.dart collapse onto one entry, the second read overwrites the first, and
      // the check that was overwritten is reported by nothing at all.
      final Map<String, String> libraries = <String, String>{
        for (final FileSystemEntity each in Directory(
          checkLibraryDirectory,
        ).listSync(recursive: true))
          if (each is File && each.path.endsWith('.dart')) pathOf(each): each.readAsStringSync(),
      };
      expect(libraries, isNotEmpty, reason: 'a check over nothing reads like a pass');

      final Set<String> tests = <String>{
        for (final FileSystemEntity each in Directory(checkTestDirectory).listSync(recursive: true))
          if (each is File && each.path.endsWith('_test.dart')) pathOf(each),
      };
      expect(tests, isNotEmpty, reason: 'a check over nothing reads like a pass');

      final int named = libraries.values.where((String each) => checkNameIn(each) != null).length;
      expect(named, greaterThan(1), reason: 'no library names a check — nothing was read');

      expect(
        auditCheckRegister(
          libraries: libraries,
          tests: tests,
          packageLibrary: File(packageLibraryPath).readAsStringSync(),
        ).map((RegisterFinding each) => each.toString()),
        isEmpty,
      );
    });
  });

  group('what names a check', () {
    test('the first line of the library doc comment does', () {
      expect(checkNameIn('/// chart-paths — every path resolves.\nlibrary;'), 'chart-paths');
    });

    test('a first line with no name names none, however it opens', () {
      expect(checkNameIn('/// The sibling checkouts these checks read.\nlibrary;'), isNull);
      expect(checkNameIn('/// chart-paths, and every path resolves.\nlibrary;'), isNull);
    });

    test(
      'the doc comment ends at the first line that is not one, so a member cannot supply it',
      () {
        const String source =
            '/// The sibling checkouts.\n'
            'library;\n'
            '\n'
            '/// chart-paths — $limitsHeading and $noCheckHeading are stated down here.\n'
            'const String path = "";\n';
        expect(checkNameIn(source), isNull);
        expect(statesLimitsIn(source), isFalse);
        expect(declaresNoCheckIn(source), isFalse);
      },
    );

    test('a library carrying no check says so in its own doc comment', () {
      expect(
        declaresNoCheckIn('/// The sibling checkouts.\n/// **$noCheckHeading.** It finds them.\n'),
        isTrue,
      );
      expect(declaresNoCheckIn('/// The sibling checkouts these checks read.\nlibrary;'), isFalse);
    });

    test('the name a file stands in is derived from the file name alone', () {
      expect(checkNameOf('$checkLibraryDirectory/chart_paths.dart'), 'chart-paths');
      expect(
        testPathOf('$checkLibraryDirectory/chart_paths.dart'),
        '$checkTestDirectory/chart_paths_test.dart',
      );
      expect(
        libraryPathOf('$checkTestDirectory/chart_paths_test.dart'),
        '$checkLibraryDirectory/chart_paths.dart',
      );
    });

    test('the exports are read as the paths the libraries stand at', () {
      expect(
        exportedLibrariesIn("export 'src/chart_paths.dart';\nexport 'src/helper.dart';"),
        <String>{'$checkLibraryDirectory/chart_paths.dart', '$checkLibraryDirectory/helper.dart'},
      );
    });
  });

  group('what it reports', () {
    /// A package of one complete check and one helper, before a probe changes one thing about it.
    ({Map<String, String> libraries, Set<String> tests, String packageLibrary}) whole() => (
      libraries: <String, String>{
        '$checkLibraryDirectory/chart_paths.dart':
            '/// chart-paths — every path resolves.\n'
            '///\n'
            '/// **$limitsHeading.** Another repository\'s files.\n'
            'library;\n',
        '$checkLibraryDirectory/installation_tree.dart':
            '/// The sibling checkouts these checks read.\n'
            '///\n'
            '/// **$noCheckHeading.** It finds them and judges nothing.\n'
            'library;\n',
      },
      tests: <String>{'$checkTestDirectory/chart_paths_test.dart'},
      packageLibrary: "export 'src/chart_paths.dart';\nexport 'src/installation_tree.dart';\n",
    );

    /// What [audit] reports over the package [whole] plus whatever a probe changed.
    List<String> report({
      Map<String, String>? libraries,
      Set<String>? tests,
      String? packageLibrary,
    }) {
      final ({Map<String, String> libraries, Set<String> tests, String packageLibrary}) package =
          whole();
      return auditCheckRegister(
        libraries: libraries ?? package.libraries,
        tests: tests ?? package.tests,
        packageLibrary: packageLibrary ?? package.packageLibrary,
      ).map((RegisterFinding each) => each.toString()).toList();
    }

    test('THE PLANTED INNOCENT: a whole package, a check and a helper beside it', () {
      expect(report(), isEmpty);
    });

    test('the planted defect: a library the package library exports nowhere', () {
      expect(report(packageLibrary: "export 'src/installation_tree.dart';\n"), <Matcher>[
        allOf(
          contains('$checkLibraryDirectory/chart_paths.dart'),
          contains('exported by no line of $packageLibraryPath'),
        ),
      ]);
    });

    test('the planted defect: a check whose suite somebody deleted', () {
      expect(report(tests: const <String>{}), <Matcher>[
        allOf(
          contains('$checkLibraryDirectory/chart_paths.dart'),
          contains('$checkTestDirectory/chart_paths_test.dart stands beside it'),
        ),
      ]);
    });

    test('the planted defect: a suite whose check nobody wrote', () {
      expect(
        report(
          tests: <String>{
            '$checkTestDirectory/chart_paths_test.dart',
            '$checkTestDirectory/published_databases_test.dart',
          },
        ),
        <Matcher>[
          allOf(
            contains('$checkTestDirectory/published_databases_test.dart'),
            contains('no $checkLibraryDirectory/published_databases.dart stands under'),
          ),
        ],
      );
    });

    test('the planted defect: a suite standing over a library that names no check', () {
      expect(
        report(
          tests: <String>{
            '$checkTestDirectory/chart_paths_test.dart',
            '$checkTestDirectory/installation_tree_test.dart',
          },
        ),
        <Matcher>[
          allOf(
            contains('$checkTestDirectory/installation_tree_test.dart'),
            contains('opens by naming no check'),
          ),
        ],
      );
    });

    test('the planted defect: a check named one thing and standing in another', () {
      final ({Map<String, String> libraries, Set<String> tests, String packageLibrary}) package =
          whole();
      final Map<String, String> renamed = <String, String>{
        ...package.libraries,
        '$checkLibraryDirectory/chart_paths.dart': package
            .libraries['$checkLibraryDirectory/chart_paths.dart']!
            .replaceFirst('chart-paths —', 'chart-path —'),
      };
      expect(report(libraries: renamed), <Matcher>[
        allOf(contains('naming the check "chart-path"'), contains('names "chart-paths"')),
      ]);
    });

    test('the planted defect: a check that says nowhere what it does not reach', () {
      final ({Map<String, String> libraries, Set<String> tests, String packageLibrary}) package =
          whole();
      final Map<String, String> silent = <String, String>{
        ...package.libraries,
        '$checkLibraryDirectory/chart_paths.dart':
            '/// chart-paths — every path resolves.\nlibrary;\n',
      };
      expect(report(libraries: silent), <Matcher>[
        allOf(contains('chart_paths.dart'), contains('says "$limitsHeading" nowhere')),
      ]);
    });

    test('the planted defect: a check demoted to a helper by having its name deleted', () {
      final ({Map<String, String> libraries, Set<String> tests, String packageLibrary}) package =
          whole();
      final Map<String, String> unnamed = <String, String>{
        ...package.libraries,
        '$checkLibraryDirectory/chart_paths.dart':
            '/// The paths the chart material names.\n'
            '///\n'
            '/// **$limitsHeading.** Another repository\'s files.\n'
            'library;\n',
      };
      expect(report(libraries: unnamed, tests: const <String>{}), <Matcher>[
        allOf(
          contains('$checkLibraryDirectory/chart_paths.dart'),
          contains('opens by naming no check and says "$noCheckHeading" nowhere'),
        ),
      ]);
    });

    test('the planted defect: a second library of one name, standing one directory down', () {
      final ({Map<String, String> libraries, Set<String> tests, String packageLibrary}) package =
          whole();
      final Map<String, String> shadowed = <String, String>{
        ...package.libraries,
        '$checkLibraryDirectory/sub/chart_paths.dart': '/// A nameless neighbour.\nlibrary;\n',
      };
      expect(report(libraries: shadowed), <Matcher>[
        allOf(
          contains('$checkLibraryDirectory/sub/chart_paths.dart'),
          contains('stands below a subdirectory of $checkLibraryDirectory'),
        ),
      ]);
    });

    test('the planted defect: a suite standing one directory down', () {
      expect(
        report(
          tests: <String>{
            '$checkTestDirectory/chart_paths_test.dart',
            '$checkTestDirectory/sub/orphan_test.dart',
          },
        ),
        <Matcher>[
          allOf(
            contains('$checkTestDirectory/sub/orphan_test.dart'),
            contains('stands below a subdirectory of $checkTestDirectory'),
          ),
        ],
      );
    });

    test('the planted defect: a check whose only suite was moved one directory down', () {
      expect(report(tests: <String>{'$checkTestDirectory/sub/chart_paths_test.dart'}), <Matcher>[
        allOf(
          contains('$checkLibraryDirectory/chart_paths.dart'),
          contains('$checkTestDirectory/chart_paths_test.dart stands beside it'),
        ),
        allOf(
          contains('$checkTestDirectory/sub/chart_paths_test.dart'),
          contains('stands below a subdirectory of $checkTestDirectory'),
        ),
      ]);
    });

    test('THE INNOCENT NEIGHBOUR: a helper needs no suite and no name of its own', () {
      final ({Map<String, String> libraries, Set<String> tests, String packageLibrary}) package =
          whole();
      final Map<String, String> second = <String, String>{
        ...package.libraries,
        '$checkLibraryDirectory/tree_search.dart':
            '/// A second helper.\n'
            '///\n'
            '/// **$noCheckHeading.** It searches and judges nothing.\n'
            'library;\n',
      };
      expect(
        report(
          libraries: second,
          packageLibrary: '${package.packageLibrary}export \'src/tree_search.dart\';\n',
        ),
        isEmpty,
      );
    });
  });
}
