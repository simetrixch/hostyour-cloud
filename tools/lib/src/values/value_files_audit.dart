import '../branch/branch_class.dart';
import '../branch/class_declaration.dart';
import '../tree/source_tree.dart';
import 'generator_manifest.dart';
import 'named_value_file.dart';
import 'value_files_finding.dart';

/// Every values file the generators of this tree name, and whether the ones that must be here are.
///
/// WHAT MAKES THIS NECESSARY IS A FLAG. `ignoreMissingValueFiles: true` in
/// `argocd/<stage>/apps/applicationset.yaml` and `argocd/<stage>/apps/tenants-appset.yaml` tells the
/// reconciler to render an Application even when a file its `helm.valueFiles` names is not there.
/// That is deliberate: an installation that has not built yet has no pins file, and an app that
/// needs no per-app installation values has no `cluster/values/<app>.yaml`. It also means a values
/// file that goes MISSING by accident produces the same silence as one that was never expected —
/// every Application keeps rendering, from whatever files are left, with no sync error anywhere.
///
/// THE DIFFICULTY IS THE DISTINCTION AND NOT THE COMPARISON. Which of the named files MUST be here
/// is not readable from the file name: `values-common.yaml` is a product file of this repository
/// under one source and a consumer's own file under the next. It follows from two things the
/// manifests already state — which repository the source rides on ([ValueFileStanding]) — and from
/// the one file that says what a path of this repository IS: branch-classes.yaml. A path it calls
/// `product` goes to every installation byte-identical, so no installation may be without it; a path
/// it calls `install` or `books` belongs to one installation and is absent here by construction.
///
/// WHAT IT DOES NOT REACH is the other repositories. The tenant generator names the member chart's
/// own `values.yaml` and `values-<stage>.yaml` in the tenant catalog, and the consumer generator
/// names the consumer's in the consumer's repository. Those are product files too — of THEIR
/// repository — and a check here could only read them where somebody happened to have them cloned,
/// which would be green because it found nothing rather than because they are there. For those the
/// flag stays a silence, and the manifests say so where they set it.
final class ValueFilesAudit {
  /// The audit of [tree] against what [declaration] says its paths are.
  ValueFilesAudit({required this.tree, required this.declaration});

  /// The tree being decided about.
  final SourceTree tree;

  /// What it declares about itself.
  final ClassDeclaration declaration;

  List<GeneratorManifest>? _manifests;
  List<NamedValueFile>? _named;

  /// Every ApplicationSet of the tree, in path order.
  List<GeneratorManifest> manifests() => _manifests ??= GeneratorManifest.allIn(tree);

  /// Every values file every generator names, in the order they stand.
  List<NamedValueFile> namedFiles() => _named ??= <NamedValueFile>[
    for (final GeneratorManifest manifest in manifests()) ...manifest.namedValueFiles(),
  ];

  /// The paths of this repository the generators require to be here, sorted and without repeats.
  ///
  /// This is what the check holds, and it is what a person reads to see how much that is.
  List<String> requiredPaths() {
    final Set<String> required = <String>{};
    for (final NamedValueFile named in namedFiles()) {
      if (named.standing case InThisRepository(:final String path) when _isProduct(path)) {
        required.add(path);
      }
    }
    final List<String> sorted = required.toList(growable: false)..sort();
    return sorted;
  }

  /// Everything wrong with the values files this tree's generators name.
  List<ValueFilesFinding> findings() => <ValueFilesFinding>[
    ...generatorsThatWereNotRead(),
    ...productFilesThatAreGone(),
    ...filesThatCannotBePlaced(),
  ];

  /// Every product values file of this repository a generator names and the tree does not carry.
  ///
  /// Reported once per position that names it: the same file named by three stage generators is
  /// three lines to correct, and reporting one of them would send somebody back twice.
  List<ValueFilesFinding> productFilesThatAreGone() {
    final List<ValueFilesFinding> found = <ValueFilesFinding>[];
    final Set<String> said = <String>{};
    for (final NamedValueFile named in namedFiles()) {
      if (named.standing case InThisRepository(:final String path)) {
        if (!_isProduct(path) || tree.holds(path)) {
          continue;
        }
        if (said.add('${named.manifest}:${named.line}:$path')) {
          found.add(
            ProductValuesFileIsGone(
              manifest: named.manifest,
              line: named.line,
              entry: named.entry,
              path: path,
            ),
          );
        }
      }
    }
    return found;
  }

  /// Every entry nothing in its own manifest explains.
  List<ValueFilesFinding> filesThatCannotBePlaced() => <ValueFilesFinding>[
    for (final NamedValueFile named in namedFiles())
      if (named.standing case Unplaceable(:final String why))
        ValueFileCannotBePlaced(
          manifest: named.manifest,
          line: named.line,
          entry: named.entry,
          why: why,
        ),
  ];

  /// The generators this check failed to read, and the case where it read nothing at all.
  List<ValueFilesFinding> generatorsThatWereNotRead() {
    if (namedFiles().isEmpty) {
      return const <ValueFilesFinding>[NoGeneratorNamesAValuesFile()];
    }
    return <ValueFilesFinding>[
      for (final GeneratorManifest manifest in manifests())
        if (manifest.namesValueFiles && manifest.namedValueFiles().isEmpty)
          ValueFilesWereNotRead(manifest.path),
    ];
  }

  bool _isProduct(String path) => declaration.ownerOf(path)?.declared == BranchClass.product;
}
