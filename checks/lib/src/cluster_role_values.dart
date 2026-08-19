/// The role a cluster carries, held against what the generators can actually match.
///
/// **WHY A ROLE VALUE IS DANGEROUS AND NOT MERELY A WORD.** It is one identity across a repository
/// boundary: the installation's own repository states it as an answer and stamps it into the app
/// generator's selector, this repository writes it into every `apps/<name>/app.yaml` as `runsOn:`,
/// and the manager writes it into every registration. If the two sides ever spell it differently,
/// **the generator matches nothing — and an ApplicationSet that matches nothing produces zero
/// Applications and no error at all.** The cluster runs, ArgoCD reports green, and not one
/// consumer or tenant is deployed. That is a fault nobody sees for days.
///
/// **THE ADMITTED SET IS DERIVED, NEVER RESTATED.** A list of role values written into this check
/// would be a third spelling of the same identity, and the drift it is watching for would then be
/// able to happen inside the guard. So the two ends are read where they are decided:
///
///   * the values the app generator's selector admits, out of `argocd/apps/applicationset.yaml` —
///     literals, plus the placeholder that stands for whatever role this branch is stamped with
///   * the values a role may hold, out of the `allowed:` of the `role` answer in the installation's
///     `deploy-branch` program — the same answer that stamp is taken from
///
/// **What is judged.** Every `runsOn:` in `apps/*/app.yaml`, and every role a generator's
/// `matchLabels` names. A value that is neither a literal the selector admits nor a role the answer
/// allows can never match, whatever machine it meets.
library;

/// One place naming a role value that nothing can match, and why it cannot.
final class UnmatchableRole {
  /// Names the value at [where], which cannot match [because].
  const UnmatchableRole({required this.where, required this.value, required this.because});

  /// The file the value stands in, as the tree names it.
  final String where;

  /// The value itself, exactly as written.
  final String value;

  /// What is wrong with it, in the words whoever wrote it reads.
  final String because;

  @override
  String toString() => '$where: "$value" $because';
}

/// What the app generator's selector admits.
typedef RunsOnSelector = ({Set<String> literals, bool stampedRole});

/// The placeholder a generated branch has the cluster's own role stamped over.
///
/// Named here because it is what makes the selector's list open-ended: everything else in it is a
/// value that matches itself, and this one matches whatever the branch was cut for.
const String clusterRolePlaceholder = '__CLUSTER_ROLE__';

final RegExp _allowedOfRole = RegExp(
  r'^\s*-\s*name:\s*role\s*$(?:\n(?!\s*-\s*name:).*)*?\n\s*allowed:\s*\[([^\]]*)\]',
  multiLine: true,
);

/// The role values [program] allows, out of the `allowed:` of its `role` answer.
///
/// Empty where the program declares no such answer, which the audit treats as a refusal rather than
/// as "nothing is allowed": a comparison against an empty set would report every value in the tree
/// and drown the one that is actually wrong.
Set<String> allowedRolesIn(String program) {
  final RegExpMatch? found = _allowedOfRole.firstMatch(program);
  if (found == null) {
    return const <String>{};
  }
  return <String>{
    for (final String each in found.group(1)!.split(','))
      if (each.trim().replaceAll(RegExp('^[\'"]|[\'"]\$'), '') case final String value)
        if (value.isNotEmpty) value,
  };
}

final RegExp _runsOnExpression = RegExp(
  r'^\s*-\s*key:\s*runsOn\s*$(?:\n\s*operator:\s*In\s*$)?\n\s*values:\s*$((?:\n\s*-\s*\S+)+)',
  multiLine: true,
);

/// What the selector in [applicationSet] admits for `runsOn`.
///
/// The `stampedRole` half says whether the placeholder is among the values, which is what makes the
/// set open to every role rather than closed to the literals alone.
RunsOnSelector runsOnSelectorIn(String applicationSet) {
  final RegExpMatch? found = _runsOnExpression.firstMatch(applicationSet);
  if (found == null) {
    return (literals: const <String>{}, stampedRole: false);
  }
  final Set<String> written = <String>{
    for (final String line in found.group(1)!.split('\n'))
      if (line.trim().startsWith('-'))
        if (line.trim().substring(1).trim() case final String value)
          if (value.isNotEmpty) value,
  };
  return (
    literals: written.where((String each) => each != clusterRolePlaceholder).toSet(),
    stampedRole: written.contains(clusterRolePlaceholder),
  );
}

final RegExp _runsOnValue = RegExp(r'^runsOn:\s*(\S+)\s*$', multiLine: true);

/// The `runsOn:` [manifest] declares, or null where it declares none.
String? runsOnIn(String manifest) => _runsOnValue.firstMatch(manifest)?.group(1);

final RegExp _matchLabelsBlock = RegExp(r'^(\s*)matchLabels:\s*(#.*)?$');
final RegExp _roleLabel = RegExp(r'^(\s*)role:\s*(\S+)\s*$');

/// Every role a `matchLabels:` block in [generator] selects on.
///
/// A generator selecting a role the answer does not allow is the same defect from the other end: the
/// label it matches on is one no cluster map will ever carry.
///
/// **Only inside a `matchLabels:` block, and that is the whole difficulty.** The word `role` names
/// several unrelated things in this tree — a Vault auth role under `auth.kubernetes`, an ArgoCD
/// project role — and a reader that took every `role:` line would report those as broken cluster
/// roles. So the block is entered by name and left by indentation, exactly the way a label block is
/// read elsewhere here.
Set<String> selectedRolesIn(String generator) {
  final Set<String> roles = <String>{};
  int? block;
  for (final String line in generator.split('\n')) {
    final String content = line.endsWith('\r') ? line.substring(0, line.length - 1) : line;
    if (content.trim().isEmpty) {
      continue;
    }
    final int indent = content.length - content.trimLeft().length;
    if (block != null) {
      if (indent <= block) {
        block = null;
      } else {
        if (_roleLabel.firstMatch(content) case final RegExpMatch found) {
          final String value = found.group(2)!;
          if (value != clusterRolePlaceholder) {
            roles.add(value);
          }
        }
        continue;
      }
    }
    block = _matchLabelsBlock.firstMatch(content)?.group(1)!.length;
  }
  return roles;
}

/// Every value of [runsOn] and [selectedRoles] that neither [selector] nor [allowedRoles] admits.
///
/// [runsOn] and [selectedRoles] are keyed by the file the value stands in, so a report names the
/// place to go rather than only the word that is wrong.
List<UnmatchableRole> auditClusterRoleValues({
  required Map<String, String> runsOn,
  required Map<String, String> selectedRoles,
  required RunsOnSelector selector,
  required Set<String> allowedRoles,
}) {
  final Set<String> admitted = <String>{
    ...selector.literals,
    if (selector.stampedRole) ...allowedRoles,
  };
  return <UnmatchableRole>[
    for (final MapEntry<String, String> each in runsOn.entries)
      if (!admitted.contains(each.value))
        UnmatchableRole(
          where: each.key,
          value: each.value,
          because:
              'is no value the app generator can match — it admits '
              '${_listed(selector.literals)}'
              '${selector.stampedRole ? ' and whichever role a branch is stamped with, one of ${_listed(allowedRoles)}' : ''}',
        ),
    for (final MapEntry<String, String> each in selectedRoles.entries)
      if (!allowedRoles.contains(each.value))
        UnmatchableRole(
          where: each.key,
          value: each.value,
          because:
              'is no role a cluster may carry, so this generator selects on a label no cluster map '
              'will hold — the roles are ${_listed(allowedRoles)}',
        ),
  ];
}

String _listed(Set<String> values) {
  final List<String> sorted = values.toList()..sort();
  return sorted.isEmpty ? 'nothing' : sorted.map((String each) => '"$each"').join(', ');
}
