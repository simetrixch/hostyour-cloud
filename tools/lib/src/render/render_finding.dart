import 'package:meta/meta.dart';

/// Something wrong with how this tree renders, as a value rather than as a sentence.
///
/// A finding is typed because an assertion over a list of pre-formatted strings matches on prose:
/// it passes for the wrong reason the day somebody improves the wording, and it cannot say which
/// KIND of thing was found without reading English. Every subtype carries the coordinates of what
/// it found, and [describe] is for the person reading a red run.
@immutable
sealed class RenderFinding {
  const RenderFinding();

  /// What a person needs to read in order to act on this.
  String describe();

  @override
  String toString() => describe();
}

/// A stage catalog names an app with no chart directory behind it.
@immutable
final class CatalogNamesNoChart extends RenderFinding {
  /// The catalog of [stage] names [app] and `apps/<app>` is not there.
  const CatalogNamesNoChart({required this.stage, required this.app});

  /// The stage whose catalog carries the name.
  final String stage;

  /// The name it carries.
  final String app;

  @override
  String describe() =>
      'argocd/$stage/apps/applicationset.yaml names $app in its catalog and apps/$app does not '
      'exist — the chart source is `path: "apps/{{ .name }}"`, so that Application can never sync';
}

/// A deploy toggle names an app no catalog carries.
@immutable
final class ToggleNamesNoCatalogEntry extends RenderFinding {
  /// The toggle at [path] states [named], or states nothing where [named] is null.
  const ToggleNamesNoCatalogEntry({required this.path, required this.named});

  /// The toggle file, relative to the repository root.
  final String path;

  /// What it says its app is called.
  final String? named;

  @override
  String describe() => switch (named) {
    null => '$path states no name, so the generator has nothing to merge it onto',
    final String name =>
      '$path toggles "$name", which no stage catalog carries. The generator merges the toggles '
          'onto the catalog BY NAME and discards what matches nothing, so this is not a '
          'mis-spelling that fails — it is an off switch that does nothing and an app that '
          'deploys where an operator turned it off',
  };
}

/// A chart under apps/ that no ArgoCD manifest names.
@immutable
final class ChartNothingDeploys extends RenderFinding {
  /// `apps/[app]` is named by no manifest.
  const ChartNothingDeploys(this.app);

  /// The chart directory.
  final String app;

  @override
  String describe() =>
      'apps/$app is named by no ArgoCD manifest, so nothing deploys it and there is no stack it '
      'could be rendered with — a chart nothing deploys reads exactly like a chart that renders';
}

/// helm refused to render a chart.
@immutable
final class ChartDidNotRender extends RenderFinding {
  /// `apps/[app]` did not render for [stage] at [size], and helm said [reason].
  const ChartDidNotRender({
    required this.app,
    required this.stage,
    required this.size,
    required this.reason,
  });

  /// The chart.
  final String app;

  /// The stage it was rendered for.
  final String stage;

  /// The sizing preset, where the chart carries them.
  final String? size;

  /// What helm complained about.
  final String reason;

  @override
  String describe() =>
      'apps/$app does not render for $stage${size == null ? '' : ' at size $size'}: $reason';
}

/// A rendered document no API server would accept.
@immutable
final class RenderedDocumentRejected extends RenderFinding {
  /// Document [document] of `apps/[app]` at [stage] is missing [missing].
  const RenderedDocumentRejected({
    required this.app,
    required this.stage,
    required this.size,
    required this.document,
    required this.missing,
  });

  /// The chart.
  final String app;

  /// The stage it was rendered for.
  final String stage;

  /// The sizing preset, where the chart carries them.
  final String? size;

  /// Which document of the manifest, counting from one.
  final int document;

  /// What it has not got.
  final String missing;

  @override
  String describe() =>
      'apps/$app rendered for $stage${size == null ? '' : ' at size $size'}: document $document '
      '$missing — helm answers for the template language and says nothing about what comes out of '
      'it, and a document without this is a valid YAML document and a rejected resource';
}

/// One installation's own state stands on the trunk.
@immutable
final class InstallationStateOnTheTrunk extends RenderFinding {
  /// [path] is installation state and it is here, for the reason in [why].
  const InstallationStateOnTheTrunk({required this.path, required this.why});

  /// What is standing here.
  final String path;

  /// Why that is wrong.
  final String why;

  @override
  String describe() =>
      '$path is one installation\'s own state and it stands on the trunk: $why. The fixture that '
      'renders this tree stands in for exactly that position, so it is no longer the whole of what '
      'an installation supplies and a render here proves less than it says';
}

/// The tool that renders is not there.
@immutable
final class NothingCouldBeRendered extends RenderFinding {
  /// Nothing rendered, for the reason in [why].
  const NothingCouldBeRendered(this.why);

  /// Why.
  final String why;

  @override
  String describe() =>
      '$why — a render audit that cannot render has decided nothing about this tree, and a green '
      'run that silently rendered nothing is the failure this gate exists to prevent';
}
