/// Which ArgoCD manifest renders a chart, and so which stack of values files it gets.
///
/// Three manifests render the charts under apps/ and they do not agree on the stack, so the family
/// is not decoration: it decides what a faithful render looks like, and a render with the wrong
/// stack proves something nobody deploys.
enum ChartFamily {
  /// `argocd/<stage>/apps/applicationset.yaml`, the platform apps. Its list generator names them,
  /// and `path: "apps/{{ .name }}"` makes the name the directory.
  catalog,

  /// `argocd/<stage>/apps/slaves-appset.yaml`, one chart: the catalog's stack, plus the per-slave
  /// block the generator reads out of a cluster map.
  slave,

  /// A unit template selected by a sizing preset, with the platform values above it. A unit chart
  /// has no stage identity of its own, so the preset stands where `values-<stage>.yaml` would.
  sized,

  /// A unit template the generator passes no values file at all — its own values.yaml is the whole
  /// of the base.
  bare,

  /// The unit ceiling: no values file, and six figures the registration carries because the size
  /// table they were resolved from lives in the manager's database and no cluster can read it.
  quota,

  /// No ArgoCD manifest names this chart. It is either a leftover or an app somebody added without
  /// wiring it up, and both read exactly like a chart that renders fine.
  unrendered,
}
