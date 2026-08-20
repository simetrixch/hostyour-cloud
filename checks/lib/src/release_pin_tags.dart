/// release-pin-tags — the image tag a pin carries, held against the release grammar the Controller
/// states.
///
/// **WHY A PIN'S TAG IS DANGEROUS AND NOT MERELY UNTIDY.** A `builds[]` entry in
/// `values-<stage>.yaml` is what says which image a stage runs FOR AN IMAGE THIS PLATFORM BUILDS,
/// and three mechanisms read it, none of which refuses a tag no release ever minted:
///
///   * the chart renders `<registryHost>/<image>:<tag>` from it (`charts/common`
///     `common.buildImage`), and `common.buildTag` only `required`s the key's PRESENCE
///     (`_helpers.tpl:101-105`) — so any non-empty string produces a syntactically valid image ref
///     and the defect surfaces as a pull failure on a cluster, never here;
///   * the release pipeline's bump WRITES the tag into an entry it finds by `image`
///     (`apps/consumer-build` `pipeline-release.yaml`, `bump_file`), so whatever stands there
///     survives until a release of that stage overwrites it — a stage no release has reached keeps
///     the string a person typed forever;
///   * the registry reaper's keep floor reads the same entry and treats its tag as a tag to
///     protect, so a tag naming no image protects nothing while reading like protection.
///
/// The Controller's own pin schema types the tag as a non-empty string, so a value that is not a
/// release tag passes every reader on both sides of the boundary.
///
/// **THE GRAMMAR IS READ, NEVER RESTATED.** A pattern written into this check would be a second
/// spelling of the release grammar, and the drift it is watching for could then happen inside the
/// guard. Both halves are read where they are decided, in the Controller tree:
///
///   * the release-tag grammar — [releaseTagPatternIn] over the Controller's own
///     [releaseTagConstant] in [controllerReleaseGrammar];
///   * the `-<sha7>` suffix a pushed IMAGE tag carries on top of it — [imageSuffixPatternIn] over
///     [imageSuffixConstant] in [controllerImageSuffix], the same strip the retention classifier
///     makes before it parses a tag.
///
/// **What is judged.** Every `builds[]` entry of every tracked file of this repository that states
/// pins.
///
/// **WHAT IT DOES NOT REACH, each with the reason it is not judged.**
///
///   * A tag that is not a `builds[]` pin. `apps/redis/values-common.yaml:8` states `tag: "8.8"`
///     and `apps/registry/values-common.yaml:18` states `tag: "v2.1.18"`, both under `image:`, and
///     both are correct: a vendor's own version is not a release this platform minted, so the
///     grammar here would refuse a true value.
///   * The channel CEILING — which channel may write which stage. It IS stated:
///     `platform/values-common.yaml:173-176` holds the table as a literal, the Controller reads it
///     at `server/domains/inventory/channel-stages.ts:53-60` and enforces it at
///     `server/domains/runs/defs/release.ts:106-107`. It could be read here the same way the
///     grammar is. It is not, because judging it needs the STAGE a pin belongs to held against the
///     CHANNEL its tag names, and this check reads a tag without knowing which of the two a
///     `values-common.yaml` entry serves. That is hostyour-cloud#60's subject, not a reason of
///     principle.
library;

import 'package:yaml/yaml.dart';

/// Where the release-tag grammar stands inside the Controller tree.
const String controllerReleaseGrammar = 'shared/release.ts';

/// The Controller's own name for the release-tag grammar.
const String releaseTagConstant = 'RELEASE_TAG_RE';

/// Where the image-tag suffix stands inside the Controller tree.
const String controllerImageSuffix = 'shared/registry-retention.ts';

/// The Controller's own name for the `-<sha7>` suffix a pushed image tag carries.
const String imageSuffixConstant = 'SHA7_SUFFIX';

/// One `builds[]` entry as a carrier states it: the name that keys it, and the tag it pins.
typedef PinnedTag = ({String name, String tag});

/// One pin whose tag is no tag a release minted, and why it is not.
final class OffGrammarPin {
  /// Names the pin [name] at [where], whose [tag] is wrong [because].
  const OffGrammarPin({
    required this.where,
    required this.name,
    required this.tag,
    required this.because,
  });

  /// The file the pin stands in, as the tree names it.
  final String where;

  /// The `builds[]` entry's own name, so the report says which of a file's pins is meant.
  final String name;

  /// The tag itself, exactly as written.
  final String tag;

  /// What is wrong with it, in the words whoever wrote it reads.
  final String because;

  @override
  String toString() => '$where: $name pinned at "$tag" $because';
}

/// The regular expression [source] states under [name], or null where it states none.
///
/// [source] is TypeScript and the value is a regular-expression literal, so the scan ends at the
/// closing delimiter — passing over one escaped inside the pattern and one standing in a character
/// class, where neither ends it. A constant whose value is not such a literal reads as absent, which
/// the caller refuses rather than judging a tree against nothing.
RegExp? declaredPatternIn(String source, String name) {
  final RegExpMatch? found = RegExp(
    '\\b$name\\b\\s*=\\s*(?://[^\\n]*\\n|\\s)*/',
  ).firstMatch(source);
  if (found == null) {
    return null;
  }
  final int opens = found.end;
  bool escaped = false;
  bool inClass = false;
  for (int at = opens; at < source.length; at++) {
    final String each = source[at];
    if (escaped) {
      escaped = false;
      continue;
    }
    switch (each) {
      case r'\':
        escaped = true;
      case '[':
        inClass = true;
      case ']':
        inClass = false;
      case '\n':
        return null;
      case '/':
        if (!inClass) {
          return RegExp(source.substring(opens, at));
        }
    }
  }
  return null;
}

/// The release-tag grammar [releaseSource] states, or null where it states none.
RegExp? releaseTagPatternIn(String releaseSource) =>
    declaredPatternIn(releaseSource, releaseTagConstant);

/// The `-<sha7>` image-tag suffix [retentionSource] states, or null where it states none.
RegExp? imageSuffixPatternIn(String retentionSource) =>
    declaredPatternIn(retentionSource, imageSuffixConstant);

final RegExp _buildsKey = RegExp(r'^builds:', multiLine: true);

/// Whether [values] states pins at all.
///
/// Read off the text and not off a parse, because it decides WHICH files are parsed: a values file
/// of this tree may carry go-template actions that no YAML parser accepts, and only a carrier of
/// pins has to be readable as YAML for this check to do its work.
bool statesPins(String values) => _buildsKey.hasMatch(values);

/// The pins [values] states, in the order it states them.
///
/// [where] names the file, so a refusal points at the one to fix. Everything that is not a list of
/// entries carrying a name and a tag is a refusal and never an empty answer: a carrier this cannot
/// read is a carrier nothing is judging, and that reads exactly like a carrier with nothing wrong.
List<PinnedTag> pinnedTagsIn(String where, String values) {
  final Object? document = loadYaml(values);
  if (document is! YamlMap) {
    throw StateError('$where states pins but is no YAML mapping — its pins cannot be read.');
  }
  final Object? builds = document['builds'];
  if (builds is! YamlList) {
    throw StateError('$where states a builds that is no list — its pins cannot be read.');
  }
  final List<PinnedTag> pins = <PinnedTag>[];
  for (final Object? entry in builds) {
    if (entry is! YamlMap) {
      throw StateError('$where states a builds[] entry that is no mapping.');
    }
    if (entry['name'] case final String name) {
      if (entry['tag'] case final String tag) {
        pins.add((name: name, tag: tag));
      } else {
        throw StateError('$where states a builds[] entry "$name" with no tag.');
      }
    } else {
      throw StateError('$where states a builds[] entry with no name.');
    }
  }
  return pins;
}

/// Every pin in [pins] whose tag is no tag a release minted.
///
/// [pins] is keyed by the file the entries stand in, so a report names the place to go. [imageTag]
/// is stripped off before [releaseTag] is applied — a pushed image tag carries it and a tag a
/// carrier states is usually a pushed one, which is the only difference between the two forms.
List<OffGrammarPin> auditPinTags({
  required Map<String, List<PinnedTag>> pins,
  required RegExp releaseTag,
  required RegExp imageTag,
}) {
  return <OffGrammarPin>[
    for (final MapEntry<String, List<PinnedTag>> carrier in pins.entries)
      for (final PinnedTag each in carrier.value)
        if (!releaseTag.hasMatch(each.tag.replaceFirst(imageTag, '')))
          OffGrammarPin(
            where: carrier.key,
            name: each.name,
            tag: each.tag,
            because:
                'is no tag a release minted — with the image suffix ${imageTag.pattern} taken off '
                'it must match ${releaseTag.pattern}, the grammar the Controller states in '
                '$controllerReleaseGrammar, and only the release bump writes one',
          ),
  ];
}
