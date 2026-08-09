import '../tree/source_tree.dart';
import 'abolished_word.dart';
import 'naming_finding.dart';

/// The abolished words stand in no name of this tree.
///
/// A word can hide in two places a renderer never reads: a file name and a directory name. Neither
/// is compiled, neither is templated and neither is checked by anything else, so a name outlives
/// every rewrite of what is inside it — which is why the shell programs this platform abolished
/// could come back as a file called `install.dart` and nothing would notice.
///
/// EVERY SEGMENT IS A NAME. A path is walked segment by segment, so `setup/whatever.yaml` is
/// reported for its directory and `apps/setup-cluster.yaml` for its file, and a name is judged the
/// same wherever it sits in the tree. A directory is reported once through the paths that stand
/// under it rather than once per file, because what has to change is the directory.
///
/// WHAT IT DOES NOT READ IS CONTENT. The rule is in [AbolishedWord], and it is a rule about names.
final class NamingAudit {
  /// The audit of [tree].
  const NamingAudit(this.tree);

  /// The tree being decided about.
  final SourceTree tree;

  /// Every name here that carries an abolished word, and the case where there were none to judge.
  List<NamingFinding> findings() {
    if (tree.paths.isEmpty) {
      return const <NamingFinding>[NothingWasNamed()];
    }
    return namesCarryingAnAbolishedWord();
  }

  /// Every file name and directory name carrying an abolished word, each reported once.
  ///
  /// The path a directory is reported under is the first that stands beneath it, so one renamed
  /// directory clears one finding rather than as many as it holds files.
  List<NamingFinding> namesCarryingAnAbolishedWord() {
    final List<NamingFinding> found = <NamingFinding>[];
    final Set<String> saidAlready = <String>{};
    for (final String path in tree.paths) {
      final List<String> segments = path.split('/');
      for (int at = 0; at < segments.length; at++) {
        final String segment = segments[at];
        for (final AbolishedWord word in AbolishedWord.values) {
          if (!word.isIn(segment)) {
            continue;
          }
          // A directory is named once however many files stand under it; a file name is unique
          // already, so the same key serves both.
          if (!saidAlready.add(segments.take(at + 1).join('/'))) {
            continue;
          }
          found.add(AbolishedWordInAName(path: path, segment: segment, word: word));
        }
      }
    }
    return found;
  }
}
