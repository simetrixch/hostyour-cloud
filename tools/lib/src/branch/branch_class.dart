/// What a path of this repository IS.
///
/// The distinction is what keeps an installation's own state off the trunk, so a second
/// installation can take the same tree and be a different company. It is an enum and never a
/// String because a fourth class must not be introducible by a typo: a word the declaration carries
/// that is not one of these is a rule nothing can act on, and it has to be reported rather than
/// carried along as data.
enum BranchClass {
  /// master, the trunk. The software: charts, manifests, the channel table, the release tags. A
  /// product path goes to a second installation BYTE-IDENTICAL, and nothing that names one
  /// installation may be produced here.
  product('product'),

  /// One branch per cluster, named after that cluster's FQDN. The trunk at the cluster's pinned
  /// release tag, plus that machine's own settings. An install path names one cluster or one
  /// machine.
  install('install'),

  /// What ONE installation knows about itself: its cluster maps, its consumer registrations, its
  /// tenant registrations. A books path stands on the install branch of the cluster holding the
  /// master role and is never tracked on the trunk.
  books('books'),

  /// NOT a fourth class. The file carries values of two classes at once and no class is true of the
  /// whole of it. A mixed file is a defect, not a state to keep.
  mixed('mixed');

  const BranchClass(this.word);

  /// The word the declaration writes.
  final String word;

  /// The class [word] names, or null when it names none of them.
  static BranchClass? tryParse(String word) {
    for (final BranchClass each in BranchClass.values) {
      if (each.word == word) {
        return each;
      }
    }
    return null;
  }
}
