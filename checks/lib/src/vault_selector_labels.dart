/// vault-selector-labels — every label key a deploy program's Vault namespace selectors match is a
/// key this repository's chart material sets.
///
/// **What one dead key costs, which is why this is checked at all.** Vault's kubernetes auth
/// evaluates `bound_service_account_namespace_selector` against the labels of the calling
/// ServiceAccount's namespace. A selector naming a key no namespace carries matches nothing, so the
/// role admits NO login: every ExternalSecret behind it stays unmaterialized, and the refusal an
/// operator gets names the role rather than the label that was misspelled. The defect cannot be
/// seen on a machine until the first namespace of its kind exists, which is how it shipped twice —
/// two roles selecting on a retired key, written independently, each syntactically sound on its
/// own.
///
/// **Neither side is LISTED here, both are READ.** A hand-kept list of "the" label keys is a second
/// truth: the day a chart moves a label, the list still says the old key and the check goes on
/// passing over the program that now matches nothing. So the chart side is read out of the
/// `labels:` blocks of this repository's own tree, and the program side is read out of the
/// selectors the deploy programs write.
///
/// **What cannot be read is an ERROR, never a pass.** A selector this library cannot decode is a
/// selector it cannot hold to anything, and green over it is the exact failure the check exists to
/// refuse — so extraction throws, naming the program, instead of passing over the step.
library;

import 'dart:convert';

/// The field Vault's kubernetes auth method reads a namespace label selector out of.
const String _selectorField = 'bound_service_account_namespace_selector';

/// One label key one program's Vault auth role selects namespaces by.
final class VaultSelector {
  /// Records that [program] writes a role [role] selecting namespaces by [key].
  const VaultSelector(this.program, this.role, this.key);

  /// The program, as a path that names the file somebody has to open.
  final String program;

  /// The Vault role the selector belongs to, so a finding names the row and not just the file.
  final String role;

  /// The label key the selector matches namespaces by.
  final String key;
}

/// A selector key nothing sets, and the selector that names it.
final class DeadSelectorKey {
  /// Records that nothing sets what [selector] matches by.
  const DeadSelectorKey(this.selector);

  /// The selector whose key nothing sets.
  final VaultSelector selector;

  /// The one line a refusal says about it.
  @override
  String toString() =>
      '${selector.program} role "${selector.role}" selects namespaces by "${selector.key}", which '
      'no labels: block of this repository sets — the role matches no namespace, and every login '
      'through it is refused before any policy is consulted';
}

/// Every namespace label key the Vault auth roles of [document] select by, where [document] is the
/// parsed YAML of the program standing at [program].
///
/// The walk is over the whole document rather than over a known step shape, because the selector is
/// written inside a step's `body` — a string of JSON handed to Vault — and which steps carry such a
/// body is the program's business, not this library's. Any string value that names the selector
/// field is decoded; the map it sits in is taken for the step, and that step's `role` names the row
/// in a finding.
///
/// Throws a [FormatException] naming [program] where a string names the field but the selector
/// cannot be decoded down to its keys: an unreadable selector held to nothing is a pass this check
/// may not give.
List<VaultSelector> vaultSelectorsIn({required String program, required Object? document}) {
  final List<VaultSelector> found = <VaultSelector>[];
  void walk(Object? node) {
    if (node is Map) {
      for (final Object? value in node.values) {
        if (value is String && value.contains(_selectorField)) {
          final Object? role = node['role'];
          for (final String key in _selectorKeysOf(program, value)) {
            found.add(VaultSelector(program, role is String ? role : '?', key));
          }
        } else {
          walk(value);
        }
      }
    } else if (node is List) {
      for (final Object? value in node) {
        walk(value);
      }
    }
  }

  walk(document);
  return found;
}

/// The label keys the selector inside [body] matches, or the refusal that [program] wrote one this
/// cannot read.
///
/// [body] is JSON twice over: the step body is a JSON object, and the selector field's value is
/// itself a JSON string holding the Kubernetes label selector — `matchLabels` keys, and the `key`
/// of each `matchExpressions` entry. An empty selector names no key and is not this check's
/// business; a selector of any other shape is refused.
List<String> _selectorKeysOf(String program, String body) {
  Never unreadable(String detail) => throw FormatException(
    '$program writes $_selectorField but $detail — what cannot be read cannot be held to the '
    'labels the charts set, so this is an error and never a pass',
  );

  final Object? step;
  try {
    step = jsonDecode(body);
  } on FormatException {
    unreadable('the body around it is not JSON');
  }
  if (step is! Map) {
    unreadable('the body around it is not a JSON object');
  }
  final Object? selector = step[_selectorField];
  if (selector is! String) {
    unreadable('its value is not a string of JSON');
  }
  final Object? parsed;
  try {
    parsed = jsonDecode(selector);
  } on FormatException {
    unreadable('its value does not hold JSON');
  }
  if (parsed is! Map) {
    unreadable('its value does not hold a JSON object');
  }
  final Object? labels = parsed['matchLabels'];
  final Object? expressions = parsed['matchExpressions'];
  if (labels is! Map? || expressions is! List?) {
    unreadable('its matchLabels or matchExpressions has a shape this cannot read');
  }
  if (labels == null && expressions == null && parsed.isNotEmpty) {
    unreadable('it selects by something other than matchLabels or matchExpressions');
  }
  final List<String> keys = <String>[
    if (labels != null)
      for (final Object? key in labels.keys)
        if (key is String) key,
  ];
  if (expressions != null) {
    for (final Object? each in expressions) {
      final Object? key = each is Map ? each['key'] : null;
      if (key is! String) {
        unreadable('a matchExpressions entry carries no string key');
      }
      keys.add(key);
    }
  }
  return keys;
}

/// A `labels:` line opening a block, alone on its line apart from a comment.
///
/// Anchored, so `matchLabels:` does not open one: a selector SELECTS by a key, and collecting what
/// is selected into what is set would let two selectors of the same misspelling prove each other.
final RegExp _labelsBlock = RegExp(r'^labels:\s*(#.*)?$');

/// A label key at the head of a line, with the characters a Kubernetes label key is made of.
///
/// A line a go-template writes its key onto — `{{ $k }}: ...` — does not match: what key it renders
/// ranges over data this check cannot see, and a key it cannot see is not one it may count as set.
final RegExp _labelKey = RegExp(r'^([A-Za-z0-9][A-Za-z0-9._/-]*):(\s|$)');

/// Every label key [text] sets under a `labels:` block, read off the lines rather than a parse.
///
/// Lines rather than a YAML document, because the places this repository sets namespace labels are
/// not all YAML documents: one is a Helm template that only becomes YAML when rendered, one sits
/// inside a `templatePatch` block scalar the ApplicationSet renders. The block is the run of lines
/// indented deeper than its `labels:` line; a key a template computes is passed over, so a selector
/// resting on one is reported rather than assumed to match.
Set<String> chartLabelKeysIn(String text) {
  final Set<String> keys = <String>{};
  int? block;
  for (final String line in text.split('\n')) {
    final String content = line.trimLeft();
    if (content.isEmpty || content.startsWith('#')) {
      continue;
    }
    final int indent = line.length - content.length;
    if (block != null && indent > block) {
      final RegExpMatch? key = _labelKey.firstMatch(content);
      if (key != null) {
        keys.add(key.group(1)!);
      }
      continue;
    }
    block = _labelsBlock.hasMatch(content) ? indent : null;
  }
  return keys;
}

/// Every selector of [selectors] whose key is in no `labels:` block of [labelKeys].
List<DeadSelectorKey> auditVaultSelectorLabels({
  required List<VaultSelector> selectors,
  required Set<String> labelKeys,
}) => <DeadSelectorKey>[
  for (final VaultSelector each in selectors)
    if (!labelKeys.contains(each.key)) DeadSelectorKey(each),
];
