import 'dart:io';

import 'package:meta/meta.dart';

/// The one reach outside this package: helm, asked to turn a chart into manifests.
///
/// It is a port and not a call to [Process] scattered through the audits, for the reason every
/// port in this organisation exists: the thing that decides — which charts must render, with which
/// values, and what counts as a broken result — has to be testable without the tool being present,
/// and the tool has to be replaceable by a fake that answers whatever a counter-probe needs.
///
/// A REAL IMPLEMENTATION AND A FAKE SHIP TOGETHER. `ProcessHelm` runs the binary; `FakeHelm`
/// answers from a table. An audit that took [Process] directly would be green on a machine with no
/// helm for the same reason it is green on a sound tree, and those two must never look alike.
abstract interface class Helm {
  /// Whether the tool is there at all.
  ///
  /// Asked and reported rather than assumed: a render audit that cannot render has decided nothing
  /// about the tree, and that is a finding, not a pass.
  bool get available;

  /// Makes every repository in [urls] reachable, so a dependency named against one can be fetched.
  HelmOutcome addRepositories(Set<String> urls);

  /// Vendors the dependencies of the chart at [chartDirectory] into its charts/ directory.
  ///
  /// Nothing in this repository tracks what this writes: .gitignore keeps apps/*/charts/ and
  /// apps/*/Chart.lock out, so a fresh checkout has neither and ArgoCD's repo-server is in the same
  /// position — it resolves the dependencies itself at every render.
  HelmOutcome vendorDependencies(String chartDirectory);

  /// Renders [request] and answers with the manifests or with what helm refused over.
  HelmOutcome render(ChartRender request);
}

/// One render, as ArgoCD would perform it.
@immutable
final class ChartRender {
  /// A render of the chart at [chartDirectory], released as [releaseName] into [namespace], with
  /// [valueFiles] layered in order and [values] set on top of them.
  const ChartRender({
    required this.chartDirectory,
    required this.releaseName,
    required this.namespace,
    required this.valueFiles,
    required this.values,
  });

  /// The native path of the chart being rendered.
  final String chartDirectory;

  /// What the release is called. It reaches the templates as `.Release.Name`.
  final String releaseName;

  /// Where the release is deployed. It reaches the templates as `.Release.Namespace`.
  final String namespace;

  /// The values files, in the order they layer — the later one wins.
  ///
  /// Paths are relative to [chartDirectory] where the file belongs to the tree being rendered, and
  /// absolute where it is the fixture standing in for what an installation supplies.
  final List<String> valueFiles;

  /// The values the ArgoCD generator injects on top of the files, out of a registration or a
  /// cluster map, as the dotted paths helm's `--set` takes.
  final Map<String, String> values;
}

/// What helm came to.
///
/// A sealed type rather than a manifest that is null when it failed: the two outcomes carry
/// different things, and code that has to name which one it is holding cannot read a refusal as an
/// empty render.
@immutable
sealed class HelmOutcome {
  const HelmOutcome();
}

/// helm did what was asked, and [manifest] is what came out. Empty where nothing was asked to be
/// produced, as when dependencies were vendored.
@immutable
final class HelmProduced extends HelmOutcome {
  /// An outcome carrying [manifest].
  const HelmProduced(this.manifest);

  /// What helm wrote.
  final String manifest;
}

/// helm refused, over [reason].
@immutable
final class HelmRefused extends HelmOutcome {
  /// An outcome carrying [reason].
  const HelmRefused(this.reason);

  /// What helm complained about, on one line.
  final String reason;
}
