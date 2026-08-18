/// Where the deploy programs stand whose Vault selectors this repository's labels answer.
///
/// **Why a chart repository reads an installation at all.** The namespace labels this tree sets are
/// half of one statement: the other half is the selector a deploy program writes into a Vault auth
/// role, and that program lives in the installation's own repository, beside the machines it names.
/// Either half alone proves nothing — each of the two selectors this check was built after was
/// syntactically sound on its own and dead against the charts.
///
/// **The tree is found by its SHAPE, never by a name.** What is searched for is the layout an
/// installation has — [installationPrograms] below its root — because which installation deploys
/// these charts is not this repository's to know. Whoever keeps the tree where the search does not
/// reach, or keeps two, names the one that is meant in [installationVariable] and the search does
/// not run at all.
///
/// **Absent REFUSES, and the refusal says what to do.** A comparison that can see only one side and
/// passes is precisely the defect this check exists for — a guard standing where the material it
/// judges is not. So where no installation is findable the search throws instead of letting the
/// suite skip, and the gate demands the other half rather than reporting green without it.
library;

import 'dart:io';

/// The environment variable that names the installation tree, overriding the search.
const String installationVariable = 'ANSIWISE_INSTALLATION';

/// Where the programs stand inside an installation tree.
const String installationPrograms = 'ansiwise/programs';

/// How far below a directory on the way up the search looks.
///
/// Two, which is what the shapes a checkout is met in cost: zero is a suite run from inside the
/// installation, one is a checkout standing beside this repository, two is the same checkout one
/// directory further out, where it stands when checkouts are grouped by the organisation that
/// publishes them. Deeper buys nothing that [installationVariable] does not buy exactly, and every
/// level widens what an unrelated tree can be mistaken for.
const int _searchDepth = 2;

/// The installation tree, as the environment names it or as found from where the suite runs.
Directory installationRoot() {
  if (Platform.environment[installationVariable] case final String named) {
    if (!Directory('$named/$installationPrograms').existsSync()) {
      throw StateError(
        'no programs at $named/$installationPrograms — $installationVariable names a tree that '
        'does not hold an installation.',
      );
    }
    return Directory(named);
  }
  return installationFoundFrom(Directory.current.absolute);
}

/// The installation tree found by searching from [start] upward, or a refusal saying what was
/// looked for.
///
/// The search walks upward because the depth this suite runs at is not the depth every caller runs
/// at, and at each directory on the way it looks up to [_searchDepth] below. The nearest directory
/// that holds an answer decides, and TWO answers decide nothing: a search that picked one of two
/// trees would report which programs the charts agree with without saying that it chose.
///
/// The starting directory is a PARAMETER so the search can be driven over a tree a probe planted;
/// read off the process, every shape it reaches would be measurable only against whatever checkouts
/// a machine happens to carry.
Directory installationFoundFrom(Directory start) {
  for (Directory above = start; ; above = above.parent) {
    final List<String> found = _installationsUnder(above);
    if (found.length == 1) {
      return Directory(found.single);
    }
    if (found.length > 1) {
      throw StateError(
        '${found.length} trees at or below ${above.path} hold $installationPrograms — '
        '${found.join(', ')} — and which of them these charts are deployed by is not something a '
        'search can decide. Set $installationVariable to the one you mean.',
      );
    }
    if (above.parent.path == above.path) {
      throw StateError(
        'no tree holding $installationPrograms was found from ${start.path} upward, searching each '
        'directory on the way and everything up to $_searchDepth directories below it. The labels '
        'this repository sets are held against the Vault selectors the deploy programs write, and '
        'a comparison that can see only one side may not pass. Clone the installation repository '
        'beside this one, or set $installationVariable to where it is.',
      );
    }
  }
}

/// Every tree at [above], or up to [_searchDepth] directories below it, that holds
/// [installationPrograms], sorted so the answer does not move with the order a directory is listed
/// in.
///
/// A branch ends where it answers: what an installation keeps inside its own tree is that
/// installation's business, and descending into it would turn a fixture of the same shape into a
/// second answer and refuse over both.
List<String> _installationsUnder(Directory above) {
  final List<String> found = <String>[];
  void look(Directory directory, int depth) {
    if (Directory('${directory.path}/$installationPrograms').existsSync()) {
      found.add(directory.path);
      return;
    }
    if (depth == _searchDepth) {
      return;
    }
    for (final Directory child in _directoriesIn(directory)) {
      look(child, depth + 1);
    }
  }

  look(above, 0);
  found.sort();
  return found;
}

/// The directories directly in [directory], and none where it cannot be listed.
///
/// The walk passes over whatever a workspace happens to stand beside, up to the root of the volume,
/// and some of that is not the process's to read. A refusal about one of those directories would
/// replace the refusal that says no installation was found, which is the one the caller can act on.
/// Links are not followed, so a link back into the walk is not a cycle.
List<Directory> _directoriesIn(Directory directory) {
  try {
    return <Directory>[
      for (final FileSystemEntity entry in directory.listSync(followLinks: false))
        if (entry is Directory) entry,
    ];
  } on FileSystemException {
    return const <Directory>[];
  }
}
