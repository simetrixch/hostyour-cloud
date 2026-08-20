/// app-manifest-keys — every directory under `apps/` carries an `app.yaml`, and every one of those
/// carries every key the ApplicationSet reads bare.
///
/// **What one missing key costs, which is why this is checked at all.** The generator renders its
/// template under `goTemplateOptions: [missingkey=error]`. Under that option a `{{ .key }}` against a
/// parameter map that does not carry the key is an ERROR — and one such error does not fail the one
/// Application it belongs to. It ends the whole reconcile: the controller records an ErrorOccurred
/// condition and creates NO Application at all, not even for the manifests that were complete.
///
/// So a new `apps/<name>/app.yaml` missing one line does not take itself down. It takes down every
/// application of the installation, and the message an operator gets names a template rather than the
/// file somebody added.
///
/// **The requirement is READ OUT OF THE TEMPLATE, never listed here.** A hand-kept list is a second
/// truth: the day somebody adds `{{ .region }}` to the generator, the list still says six keys and
/// the check goes on passing over the manifest that now breaks the reconcile. What is listed here is
/// only the OPPOSITE — the shapes that do not make a key required, because they already say what
/// they do when it is absent.
///
/// **WHAT IT DOES NOT REACH.** One generator, and of a key nothing but its presence. The template
/// read is `argocd/apps/applicationset.yaml` and the manifests are `apps/*/app.yaml`. The three
/// other ApplicationSets of this tree render their own templates under the same option —
/// `argocd/apps/slaves-appset.yaml:8-9`, `argocd/apps/consumers-appset.yaml:59-61` and
/// `argocd/apps/tenants-appset.yaml:74-75` — from parameter files this check reads nothing of. What
/// the slaves appset reads out of a cluster map is held by `appset_cluster_map_keys.dart` instead;
/// the consumers and tenants appsets select `registrations/*/__STAGE__.yaml` off a books branch,
/// which is tracked on no branch this suite reads, so a key either of them reads bare is held to
/// nothing anywhere.
///
/// And what is judged is PRESENCE: [auditAppManifestKeys] asks `containsKey`, so a key standing with
/// nothing after the colon answers this check exactly as a filled one does.
library;

/// A key a manifest does not carry, and the manifest that does not carry it.
final class MissingKey {
  /// Records that [manifest] carries no [key].
  const MissingKey(this.manifest, this.key);

  /// The manifest, as a path relative to the repository.
  final String manifest;

  /// The key the template reads and this manifest does not answer.
  final String key;

  /// The one line a refusal says about it.
  @override
  String toString() =>
      '$manifest carries no "$key", which the generator reads bare — one such key ends the whole '
      'reconcile, not just this application';
}

/// The keys [template] reads in a way that REQUIRES them.
///
/// A key reached through `dig "name" "" .` is not among them: `dig` answers a default where the key
/// is absent, so the template has already said what it does without it. Every other `.name` is bare,
/// and bare is what `missingkey=error` refuses.
Set<String> requiredKeysIn(String template) {
  final Set<String> optional = <String>{
    for (final RegExpMatch each in RegExp(r'dig\s+"([A-Za-z][A-Za-z0-9]*)"').allMatches(template))
      each.group(1)!,
  };
  final Set<String> read = <String>{
    for (final RegExpMatch each in RegExp(
      r'\{\{[^}]*?\.([A-Za-z][A-Za-z0-9]*)',
    ).allMatches(template))
      each.group(1)!,
  };
  return read.difference(optional);
}

/// Every key a manifest of [manifests] does not carry that [template] requires.
///
/// [manifests] is the parsed content of each `apps/<name>/app.yaml`, by the path it stands at, so a
/// finding names the file somebody has to open.
List<MissingKey> auditAppManifestKeys({
  required String template,
  required Map<String, Map<String, Object?>> manifests,
}) {
  final List<String> required = requiredKeysIn(template).toList()..sort();
  return <MissingKey>[
    for (final MapEntry<String, Map<String, Object?>> each in manifests.entries)
      for (final String key in required)
        if (!each.value.containsKey(key)) MissingKey(each.key, key),
  ];
}

/// Every directory under `apps/` that no tracked `apps/<name>/app.yaml` answers.
///
/// **Why an app.yaml is the rule and not a habit.** The generator selects `apps/*/app.yaml`
/// (`argocd/apps/applicationset.yaml`), so a directory without one is never rendered by it. From the
/// directory alone the two cases are indistinguishable: a chart somebody added and forgot to
/// declare, which is then silently absent from every cluster, and a chart that is not a platform
/// application at all and stands in the wrong place. Requiring the file of every one of them is what
/// makes the difference readable, and it is why the four per-unit charts and the per-slave chart
/// stand under `units/` and `slaves/` instead of being carried here as named exceptions.
///
/// [tracked] comes from `git ls-files`, never from the file system: an untracked directory is not on
/// the cluster's clone, and a directory whose files are all untracked is not a chart yet.
List<String> appDirectoriesWithoutManifest(Set<String> tracked) {
  final Set<String> directories = <String>{
    for (final String path in tracked)
      if (path.startsWith('apps/') && path.split('/').length > 2) path.split('/')[1],
  };
  return <String>[
    for (final String directory in directories.toList()..sort())
      if (!tracked.contains('apps/$directory/app.yaml')) 'apps/$directory',
  ];
}
