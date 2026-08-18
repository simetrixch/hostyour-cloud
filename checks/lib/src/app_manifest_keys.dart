/// app-manifest-keys — every `apps/<name>/app.yaml` carries every key the ApplicationSet reads bare.
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
