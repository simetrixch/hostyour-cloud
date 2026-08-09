/// What a `derived:` rule permits when an install branch is synced to a new pin and a file
/// conflicts.
///
/// A rule here is a licence to resolve that conflict TOWARD THE PIN, throwing the branch's side
/// away, on the grounds that a stamper regenerates it a moment later. Where no stamper does, the
/// licence deletes what only the branch had — the reason the section is measured against the
/// stampers rather than believed.
enum DerivedLicence {
  /// Every stage, both roles: a stamper writes the whole of it on every run.
  always('always'),

  /// Exactly on an installation whose stage is NOT this file's own. The role stamp removes the
  /// other two stages, and the removal is what makes the conflict moot.
  otherStages('other-stages'),

  /// Exactly where the role lacks the master part, at every stage: the role stamp removes every
  /// registration there. On the branch that HOLDS the books, resolving toward the pin would delete
  /// this installation's ledger.
  booksBranchOnly('books-branch-only'),

  /// [booksBranchOnly] with the one exception the role stamp makes by name — the branch's OWN
  /// cluster map is kept even on a role without the master part, so nothing regenerates it and it
  /// is never derived.
  foreignMapOnly('foreign-map-only');

  const DerivedLicence(this.word);

  /// The word the declaration writes.
  final String word;

  /// The licence [word] names, or null when it names none of them.
  static DerivedLicence? tryParse(String word) {
    for (final DerivedLicence each in DerivedLicence.values) {
      if (each.word == word) {
        return each;
      }
    }
    return null;
  }
}
