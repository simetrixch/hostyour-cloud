/// The sibling checkouts these checks read the other half of a statement out of.
///
/// **Why a chart repository reads another tree at all.** What this tree states is half of a
/// statement whose other half is written somewhere else, and either half alone proves nothing. The
/// namespace labels this tree sets are answered by the selector a deploy program writes into a Vault
/// auth role; the keys an ApplicationSet reads out of a cluster map are answered by the two writers
/// of that map. Each of the selectors these checks were built after was syntactically sound on its
/// own and dead against the other side.
///
/// **A tree is found by its SHAPE, never by a name.** What is searched for is the layout the tree
/// has — [installationPrograms] below an installation's root, [controllerInventory] below the
/// Controller's — because which checkout deploys or operates these charts is not this repository's
/// to know. Whoever keeps a tree where the search does not reach, or keeps two, names the one that
/// is meant in [installationVariable] or [controllerVariable] and the search does not run at all.
///
/// **Absent REFUSES, and the refusal says what to do.** A comparison that can see only one side and
/// passes is precisely the defect these checks exist for — a guard standing where the material it
/// judges is not. So where no tree is findable the search throws instead of letting the suite skip,
/// and the gate demands the other half rather than reporting green without it.
library;

import 'dart:io';

/// The environment variable that names the installation tree, overriding the search.
const String installationVariable = 'ANSIWISE_INSTALLATION';

/// Where the programs stand inside an installation tree.
const String installationPrograms = 'ansiwise/programs';

/// The environment variable that names the Controller tree, overriding the search.
const String controllerVariable = 'HOSTYOUR_CONTROLLER';

/// Where the inventory domain stands inside the Controller tree.
///
/// The Controller is the OTHER writer of a cluster map: a master's map is written by the deployment
/// programs when the cluster is installed, a slave's is written by the Controller, and which keys a
/// map may carry is answerable only with both trees in hand.
const String controllerInventory = 'server/domains/inventory';

/// How far below a directory on the way up the search looks.
///
/// Two, which is what the shapes a checkout is met in cost: zero is a suite run from inside the
/// tree, one is a checkout standing beside this repository, two is the same checkout one directory
/// further out, where it stands when checkouts are grouped by the organisation that publishes them.
/// Deeper buys nothing that naming the tree outright does not buy exactly, and every level widens
/// what an unrelated tree can be mistaken for.
const int _searchDepth = 2;

/// One kind of sibling tree: what recognises it, what names it, and what is lost without it.
final class _Kind {
  const _Kind({
    required this.marker,
    required this.variable,
    required this.subject,
    required this.stake,
  });

  /// The path below a directory that makes that directory this kind of tree.
  final String marker;

  /// The environment variable that names the tree outright.
  final String variable;

  /// What the tree is, in the words a refusal ends its sentence with.
  final String subject;

  /// What is held against what, so a refusal says what the missing tree costs.
  final String stake;
}

const _Kind _installation = _Kind(
  marker: installationPrograms,
  variable: installationVariable,
  subject: 'an installation',
  stake:
      'The labels this repository sets are held against the Vault selectors the deploy programs '
      'write, and a comparison that can see only one side may not pass.',
);

const _Kind _controller = _Kind(
  marker: controllerInventory,
  variable: controllerVariable,
  subject: 'the Controller',
  stake:
      'The keys an ApplicationSet reads out of a cluster map are held against the keys the '
      'Controller writes into one, and a comparison that can see only one side may not pass.',
);

/// The installation tree, as the environment names it or as found from where the suite runs.
Directory installationRoot() => _rootOf(_installation);

/// The Controller tree, as the environment names it or as found from where the suite runs.
Directory controllerRoot() => _rootOf(_controller);

/// The installation tree found by searching from [start] upward, or a refusal saying what was
/// looked for.
Directory installationFoundFrom(Directory start) => _foundFrom(start, _installation);

/// The tree of [kind], as its own variable names it or as found from where the suite runs.
Directory _rootOf(_Kind kind) {
  if (Platform.environment[kind.variable] case final String named) {
    if (!Directory('$named/${kind.marker}').existsSync()) {
      throw StateError(
        'nothing at $named/${kind.marker} — ${kind.variable} names a tree that does not hold '
        '${kind.subject}.',
      );
    }
    return Directory(named);
  }
  return _foundFrom(Directory.current.absolute, kind);
}

/// The tree of [kind] found by searching from [start] upward, or a refusal saying what was looked
/// for.
///
/// The search walks upward because the depth this suite runs at is not the depth every caller runs
/// at, and at each directory on the way it looks up to [_searchDepth] below. The nearest directory
/// that holds an answer decides, and TWO answers decide nothing: a search that picked one of two
/// trees would report which programs the charts agree with without saying that it chose.
///
/// The starting directory is a PARAMETER so the search can be driven over a tree a probe planted;
/// read off the process, every shape it reaches would be measurable only against whatever checkouts
/// a machine happens to carry.
Directory _foundFrom(Directory start, _Kind kind) {
  for (Directory above = start; ; above = above.parent) {
    final List<String> found = _treesUnder(above, kind.marker);
    if (found.length == 1) {
      return Directory(found.single);
    }
    if (found.length > 1) {
      throw StateError(
        '${found.length} trees at or below ${above.path} hold ${kind.marker} — '
        '${found.join(', ')} — and which of them these charts belong with is not something a '
        'search can decide. Set ${kind.variable} to the one you mean.',
      );
    }
    if (above.parent.path == above.path) {
      throw StateError(
        'no tree holding ${kind.marker} was found from ${start.path} upward, searching each '
        'directory on the way and everything up to $_searchDepth directories below it. '
        '${kind.stake} Clone that repository beside this one, or set ${kind.variable} to where it '
        'is.',
      );
    }
  }
}

/// Every tree at [above], or up to [_searchDepth] directories below it, that holds [marker], sorted
/// so the answer does not move with the order a directory is listed in.
///
/// A branch ends where it answers: what a tree keeps inside itself is that tree's business, and
/// descending into it would turn a fixture of the same shape into a second answer and refuse over
/// both.
List<String> _treesUnder(Directory above, String marker) {
  final List<String> found = <String>[];
  void look(Directory directory, int depth) {
    if (Directory('${directory.path}/$marker').existsSync()) {
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
/// replace the refusal that says no tree was found, which is the one the caller can act on.
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
