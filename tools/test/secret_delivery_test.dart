import 'dart:io';

import 'package:hostyour_cloud_gate/hostyour_cloud_gate.dart';
import 'package:test/test.dart';

import 'support/repository_under_check.dart';

/// Every ExternalSecret of this repository carries the platform-wide secret delivery rule.
///
/// The audit is [SecretDeliveryAudit]; this file drives it over the repository, where its findings
/// must be empty, and over a tree planted for the purpose that carries one instance of every defect
/// it is supposed to find, each beside a correct neighbour.
///
/// It also asserts the two ends the audit sits between: the chart whose comment states the rule in
/// full is one of the documents judged, and the vendored CustomResourceDefinition that merely NAMES
/// the kind is not — a scan that took every `kind: ExternalSecret` line in the tree would report the
/// definition of the resource for carrying upstream's defaults, which is what it is for.
void main() {
  final Directory scratch = Directory.systemTemp.createTempSync('hostyour-secrets-');
  final SourceTree tree = repositoryTree();
  final SecretDeliveryAudit audit = SecretDeliveryAudit(tree);

  tearDownAll(() => scratch.deleteSync(recursive: true));

  group('the repository', () {
    test('carries ExternalSecrets to judge', () {
      expect(
        audit.documents(),
        isNotEmpty,
        reason: 'nothing of the kind was read, so this check measured nothing',
      );
    });

    test('states both lines of the rule as literals in every one of them', () {
      final List<SecretDeliveryFinding> found = audit.fieldsOffTheRule();
      expect(found, isEmpty, reason: found.join('\n'));
    });

    test('the chart that states the rule in full is one of the documents judged', () {
      expect(
        audit.documents().map((ExternalSecretDocument d) => d.path),
        contains('charts/external-secret/templates/externalsecret.yaml'),
        reason:
            'the library chart every app renders its ExternalSecret through; if it is gone from '
            'this list the rule is stated in a file nothing measures',
      );
    });

    test('this file, which plants three of them, is not judged as chart material', () {
      expect(tree.holds('tools/test/secret_delivery_test.dart'), isTrue);
      expect(
        audit.documents().map((ExternalSecretDocument d) => d.path),
        isNot(contains('tools/test/secret_delivery_test.dart')),
        reason:
            'the counter-probe below writes three manifests off the rule into this Dart source; an '
            'audit that scanned every tracked path would report the fixtures that prove it works',
      );
    });

    test('the CustomResourceDefinition that only names the kind is not judged as one', () {
      expect(
        audit.documents().map((ExternalSecretDocument d) => d.path),
        isNot(contains('apps/external-secrets/templates/crd-externalsecret.yaml')),
        reason:
            'the vendored CRD states refreshPolicy and refreshInterval as schema properties with '
            'upstream\'s defaults behind them; judging it by the rule its instances carry would '
            'report the definition of the resource',
      );
    });
  });

  group('what counts as stating a literal', () {
    test('the literal itself is', () {
      expect(RefreshField.refreshPolicy.isStatedLiterallyBy('OnChange'), isTrue);
      expect(RefreshField.refreshInterval.isStatedLiterallyBy('"0"'), isTrue);
    });

    test('the literal with a comment after it still is, because no byte a cluster reads moved', () {
      expect(
        RefreshField.refreshPolicy.isStatedLiterallyBy('OnChange # the delivery rule'),
        isTrue,
      );
      expect(RefreshField.refreshInterval.isStatedLiterallyBy('"0"   # nothing polls'), isTrue);
    });

    test('a template expression is not, whatever it would resolve to', () {
      expect(
        RefreshField.refreshPolicy.isStatedLiterallyBy(
          '{{ .Values.externalSecret.refreshPolicy }}',
        ),
        isFalse,
      );
      expect(
        RefreshField.refreshInterval.isStatedLiterallyBy(
          '{{ .Values.externalSecret.refreshInterval | default "0" }}',
        ),
        isFalse,
      );
    });

    test('an unquoted zero is not, because "0" and 0 are two different scalars', () {
      expect(RefreshField.refreshInterval.isStatedLiterallyBy('0'), isFalse);
    });

    test('another interval is not', () {
      expect(RefreshField.refreshInterval.isStatedLiterallyBy('1h'), isFalse);
      expect(RefreshField.refreshPolicy.isStatedLiterallyBy('Periodic'), isFalse);
    });
  });

  group('counter-probe', () {
    late SecretDeliveryAudit probe;
    late List<SecretDeliveryFinding> found;

    setUpAll(() {
      probe = SecretDeliveryAudit(
        SourceTree.planted(
          Directory('${scratch.path}${Platform.pathSeparator}probe')..createSync(recursive: true),
          const <String, String>{
            'apps/probe/templates/externalsecret-overridden.yaml': _overridden,
            'apps/probe/templates/externalsecret-silent.yaml': _silent,
            'apps/probe/templates/externalsecret-pair.yaml': _pair,
            'apps/probe/templates/crd.yaml': _definitionOfTheKind,
          },
        ),
      );
      found = probe.findings();
    });

    test('a policy standing behind a template expression is reported, on its own line', () {
      expect(
        found,
        contains(
          predicate<SecretDeliveryFinding>(
            (SecretDeliveryFinding f) =>
                f is RefreshFieldIsNotTheLiteral &&
                f.field == RefreshField.refreshPolicy &&
                f.path == 'apps/probe/templates/externalsecret-overridden.yaml' &&
                f.line == 7,
          ),
        ),
        reason: 'the literal scan cannot go red, or it reported the commented-out line above it',
      );
    });

    test('an interval that is not "0" is reported', () {
      expect(
        found,
        contains(
          predicate<SecretDeliveryFinding>(
            (SecretDeliveryFinding f) =>
                f is RefreshFieldIsNotTheLiteral &&
                f.field == RefreshField.refreshInterval &&
                f.path == 'apps/probe/templates/externalsecret-overridden.yaml' &&
                f.line == 8,
          ),
        ),
      );
    });

    for (final RefreshField field in RefreshField.values) {
      test('a document stating no ${field.key} at all is reported, at its kind line', () {
        expect(
          found,
          contains(
            predicate<SecretDeliveryFinding>(
              (SecretDeliveryFinding f) =>
                  f is RefreshFieldIsMissing &&
                  f.field == field &&
                  f.path == 'apps/probe/templates/externalsecret-silent.yaml' &&
                  f.kindLine == 2,
            ),
          ),
        );
      });
    }

    test('the second document of a file is judged, at the line it really stands on', () {
      expect(
        found,
        contains(
          predicate<SecretDeliveryFinding>(
            (SecretDeliveryFinding f) =>
                f is RefreshFieldIsNotTheLiteral &&
                f.field == RefreshField.refreshInterval &&
                f.path == 'apps/probe/templates/externalsecret-pair.yaml' &&
                f.line == 15,
          ),
        ),
        reason: 'a file is split at every `---`, or only its first resource is ever decided about',
      );
    });

    test('the correct document beside it is not reported', () {
      expect(
        found.where(
          (SecretDeliveryFinding f) =>
              f is RefreshFieldIsNotTheLiteral &&
              f.path == 'apps/probe/templates/externalsecret-pair.yaml',
        ),
        hasLength(1),
        reason:
            'the file holds two documents and only the second is off the rule; the neighbour '
            'states both literals, one of them with a comment after it',
      );
    });

    test('a definition of the kind is not read as an instance of it', () {
      expect(
        probe.documents().map((ExternalSecretDocument d) => d.path),
        isNot(contains('apps/probe/templates/crd.yaml')),
        reason: 'the kind is read at column 0, or every CRD in the tree is judged as a manifest',
      );
    });

    test('a tree holding no document of the kind is reported as measuring nothing', () {
      final Directory bare = Directory('${scratch.path}${Platform.pathSeparator}bare')
        ..createSync(recursive: true);
      expect(
        SecretDeliveryAudit(
          SourceTree.planted(bare, const <String, String>{'apps/probe/values.yaml': 'a: b\n'}),
        ).findings(),
        <Matcher>[isA<NoExternalSecretWasRead>()],
      );
    });
  });
}

/// A manifest that hands both lines of the rule to a values file, with the rule commented out above
/// them — so the reported line is the one that renders, not the one that explains.
const String _overridden = '''
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: probe-overridden
spec:
  # refreshPolicy: OnChange
  refreshPolicy: {{ .Values.probe.refreshPolicy }}
  refreshInterval: 1h
''';

/// A manifest that states neither line, which is the shape that falls back to upstream's default
/// without anything in the file saying so.
const String _silent = '''
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: probe-silent
spec:
  secretStoreRef:
    name: vault-backend
''';

/// Two documents in one file: the correct one first, carrying a comment after its interval, and a
/// polling one behind the separator.
const String _pair = '''
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: probe-correct
spec:
  refreshPolicy: OnChange
  refreshInterval: "0"   # nothing here polls
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: probe-second
spec:
  refreshPolicy: OnChange
  refreshInterval: "3600"
''';

/// The shape of the vendored CRD: it NAMES the kind, indented, and states the two keys as schema
/// properties carrying upstream's defaults.
const String _definitionOfTheKind = '''
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: externalsecrets.external-secrets.io
spec:
  names:
    kind: ExternalSecret
  versions:
    - schema:
        openAPIV3Schema:
          properties:
            refreshInterval:
              default: 1h
            refreshPolicy:
              default: Periodic
''';
