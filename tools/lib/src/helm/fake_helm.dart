import 'helm.dart';

/// A [Helm] that answers from a table, so an audit can be driven where the tool is not.
///
/// Every render it is asked for is recorded in [renders]. That is how the ORDER of the values files
/// is asserted: the order is the whole of what makes a render faithful to what ArgoCD does, and it
/// cannot be seen in the manifests that come out — two stacks in the wrong order render, and render
/// something nobody deploys.
final class FakeHelm implements Helm {
  /// A helm that answers [outcomes] by release name, and [fallback] for anything else.
  FakeHelm({
    this.available = true,
    Map<String, HelmOutcome>? outcomes,
    this.fallback = const HelmProduced(''),
  }) : _outcomes = outcomes ?? const <String, HelmOutcome>{};

  @override
  final bool available;

  /// What is answered for a release nothing in the table names.
  final HelmOutcome fallback;

  final Map<String, HelmOutcome> _outcomes;

  /// Every render this was asked for, in the order it was asked.
  final List<ChartRender> renders = <ChartRender>[];

  /// Every chart directory whose dependencies this was asked to vendor, in order.
  final List<String> vendored = <String>[];

  /// Every repository URL this was asked to add, in order.
  final List<String> repositories = <String>[];

  @override
  HelmOutcome addRepositories(Set<String> urls) {
    repositories.addAll(urls);
    return const HelmProduced('');
  }

  @override
  HelmOutcome vendorDependencies(String chartDirectory) {
    vendored.add(chartDirectory);
    return const HelmProduced('');
  }

  @override
  HelmOutcome render(ChartRender request) {
    renders.add(request);
    return _outcomes[request.releaseName] ?? fallback;
  }
}
