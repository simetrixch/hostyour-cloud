/// The words every audit in this package needs, and the one literal none of them may carry whole.
library;

/// What the trunk says where an installation says its own name.
///
/// SPELT IN TWO PIECES ON PURPOSE, so no source file of this package carries the literal. The
/// domain stamp rewrites it in every tracked file it does not exclude by class — a path segment
/// `docs` or `templates`, the name branch-classes.yaml, a `.sh` or `.ps1` suffix, a first line
/// beginning `#!` — and a `.dart` file is none of those. Written out whole, the fixture these
/// audits render with would become a real customer's domain on every install branch, and this
/// package would be the thing that named them.
///
/// Nothing here rests on that being remembered: the branch-class audit measures the same rule from
/// the other side, so a tracked file carrying the literal and not declared in `stamped:` is a
/// finding, and every file of this package is a tracked file.
const String placeholderDomain =
    'example.'
    'invalid';

/// The cluster the render fixture pretends to be.
///
/// A master, so that everything only a master renders — the observability receive path, the
/// registry, the tailnet coordinator — is inside the render rather than switched off by a profile.
const String fixtureFqdn = 'm1.$placeholderDomain';

/// The three stages the product carries, in the order their values files layer.
///
/// An installation is exactly one of them; the trunk carries all three, which is what makes it the
/// tree every installation is cut from.
const List<String> stages = <String>['dev', 'test', 'prod'];

/// What a cluster is, as the cluster map states it and the role stamp reads it.
///
/// The role decides whether a branch keeps the books — the cluster maps and the registrations — so
/// it is a value and never a flag: a role guessed from anything deletes the books of the
/// installation that guessed wrong.
enum ClusterRole {
  /// Holds the master part, and with it this installation's books.
  master,

  /// Holds none of them; its branch is pruned of every registration and of every map but its own.
  slave,
}
