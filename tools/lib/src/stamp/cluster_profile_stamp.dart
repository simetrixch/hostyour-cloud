/// The one file a branch run renders whole, mirrored so a declaration can be measured against it.
///
/// `cluster/profile.yaml` is where an installation says where its services are — its domain, its
/// short name, its books branch, its Vault, its tailnet, its registry host, and which of those run
/// on this cluster. Every application's ArgoCD Application loads it LAST in its values chain, so
/// what stands here wins over everything the product declares, and that is what makes one tree
/// serve two companies. The trunk carries `global: {}` because it knows no installation.
///
/// The step that writes it is `StampClusterProfile`, Dart, in simetrixch/ansiwise-plugins under
/// `hostyour-cloud/lib/src/steps/branch/stamp_cluster_profile.dart`. It is a `FileStep`: `contentFor`
/// renders the entire file from the run's own answers — the fqdn, the role, the master, the build
/// plane, the unit apex, the platform domain, the tailnet and post URLs — so every byte a branch
/// holds here came out of that render and a run produces it again.
///
/// THIS IS A MIRROR AND IT CAN DRIFT. The step is in another repository and this one cannot run it,
/// so the path it writes is restated here with the member it came from, and the branch-class audit
/// drives the mirror over planted paths.
final class ClusterProfileStamp {
  /// The stamp as the step defines it.
  const ClusterProfileStamp();

  /// `StampClusterProfile.pathFor` — where the profile stands, relative to the top of the checkout.
  static const String profile = 'cluster/profile.yaml';

  /// Whether a run writes [path] again, whatever the stage and whatever the role.
  bool regenerates(String path) => path == profile;
}
