/// A word that names nothing in this tree and must not stand in a name.
///
/// WHAT WAS ABOLISHED IS A PROGRAM NAME, NOT A VERB. The shell this platform replaced had
/// `install.sh` and `setup.sh`: two programs split along a line nobody could name, which is how one
/// of them came to do five unrelated things. Both are gone, and this repository has no shell at all
/// — so a name here is the name of a THING, a chart, an application, a manifest, a values file, and
/// never the name of a program. There is no position left in which either word names something, so
/// there is no position in which either is allowed.
///
/// A WORD AND NOT A SUBSTRING, and that distinction is the whole check. `installation` is what this
/// product calls one deployment of itself — the word `branch-classes.yaml`, `cluster/profile.yaml`
/// and every chart in the tree already use — and `tools/lib/src/installation.dart` is named for it.
/// A substring match would rename that file to something that no longer says what it is, which is
/// the failure this exists to prevent arriving from the other side. Word boundaries are the
/// characters a name is built from: a hyphen, an underscore, a dot, a digit.
///
/// CONTENT IS NEVER READ. `helm install` is what the tool is called, an argocd setup job is what
/// argocd calls it, and a check that reached into the text of a chart would report the software's
/// own vocabulary back at its author.
enum AbolishedWord {
  /// One of the two abolished program names. The verbs of this platform are deploy and onboard, and
  /// what is deployed or onboarded is named after itself.
  install('install', anywhereInTheName: false),

  /// The other one, and also what a directory is called when it collects whatever somebody decided
  /// belongs to installing — the grouping that had no name in the first place.
  setup('setup', anywhereInTheName: false),

  /// Not a bad name but a false one: it states a platform. Nothing in this tree runs on a desktop —
  /// it is charts and manifests for a Kubernetes cluster — so there is no position in which the
  /// word becomes true, and it is refused wherever it sits inside a name.
  desktop('desktop', anywhereInTheName: true);

  const AbolishedWord(this.word, {required this.anywhereInTheName});

  /// The word itself.
  final String word;

  /// Whether it is refused wherever it sits inside a name, rather than only as a word of one.
  final bool anywhereInTheName;

  /// Whether [name] — one segment of a path, so one file name or one directory name — carries this
  /// word.
  ///
  /// Case-insensitive, because `Setup` is the same word wearing a disguise.
  bool isIn(String name) {
    final String lower = name.toLowerCase();
    if (anywhereInTheName) {
      return lower.contains(word);
    }
    return _wordsIn(lower).contains(word);
  }

  /// What a person needs to read in order to act on a finding about this word.
  String get because => switch (this) {
    AbolishedWord.install || AbolishedWord.setup =>
      'the abolished program name; this repository runs no programs, so a name here names a chart, '
          'a manifest or a values file, and the verbs are deploy and onboard',
    AbolishedWord.desktop => 'desktop names a platform nothing in this tree runs on',
  };

  /// The words [name] is built from, in the order they stand.
  static List<String> _wordsIn(String name) =>
      name.split(RegExp('[^a-z]+')).where((String word) => word.isNotEmpty).toList(growable: false);
}
