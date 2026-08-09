import '../tree/source_tree.dart';
import 'external_secret_document.dart';
import 'refresh_field.dart';
import 'secret_delivery_finding.dart';

/// Every ExternalSecret of this tree carries the platform-wide secret delivery rule, as a literal.
///
/// THE RULE IS ONE SENTENCE and it is stated in full in
/// charts/external-secret/templates/externalsecret.yaml: a secret reaches a cluster when it is
/// DEPLOYED and when its target Secret is DELETED, and never on a timer. Two lines of every
/// ExternalSecret spec are that sentence — `refreshPolicy: OnChange` and `refreshInterval: "0"`,
/// both explained in [RefreshField].
///
/// WHAT IS ACTUALLY AT RISK IS NOT A TYPO. Neither value is the external-secrets default, so a
/// document that states neither is not neutral: it falls back to `Periodic`, and that one namespace
/// then polls Vault while every other reads it on deploy and on delete only. A document that states
/// them as values rather than literals is worse, because the override is invisible in the template
/// and shows up only in one installation's render.
///
/// IT READS THE TREE, NOT A CLUSTER AND NOT A RENDER. Whether the running CRs match is a question
/// about one installation at one moment; whether this product can put a namespace on a different
/// delivery model is a question about the files, and the files are here. What it reads of them is
/// the chart material ([SourceTree.chartMaterial]) — a manifest is YAML, and the only other place in
/// this tree where the two lines stand written out is the counter-probe below that proves this audit
/// can go red.
final class SecretDeliveryAudit {
  /// The audit of [tree].
  const SecretDeliveryAudit(this.tree);

  /// The tree being decided about.
  final SourceTree tree;

  /// Everything in this tree that is not the delivery rule, and the case where there was nothing to
  /// judge.
  List<SecretDeliveryFinding> findings() {
    if (documents().isEmpty) {
      return const <SecretDeliveryFinding>[NoExternalSecretWasRead()];
    }
    return fieldsOffTheRule();
  }

  /// Every document of kind ExternalSecret this tree carries.
  List<ExternalSecretDocument> documents() => ExternalSecretDocument.allIn(tree);

  /// Every field of the rule a document states as something other than its literal, or not at all.
  ///
  /// Both fields of every document are decided, rather than stopping at the first: a manifest that
  /// lost one of the two lines and put a template expression in the other is one edit, and reporting
  /// half of it would send somebody back a second time.
  List<SecretDeliveryFinding> fieldsOffTheRule() {
    final List<SecretDeliveryFinding> found = <SecretDeliveryFinding>[];
    for (final ExternalSecretDocument document in documents()) {
      for (final RefreshField field in RefreshField.values) {
        final ({int line, String value})? stated = document.statementOf(field);
        if (stated == null) {
          found.add(
            RefreshFieldIsMissing(path: document.path, kindLine: document.kindLine, field: field),
          );
          continue;
        }
        if (!field.isStatedLiterallyBy(stated.value)) {
          found.add(
            RefreshFieldIsNotTheLiteral(
              path: document.path,
              line: stated.line,
              field: field,
              value: stated.value,
            ),
          );
        }
      }
    }
    return found;
  }
}
