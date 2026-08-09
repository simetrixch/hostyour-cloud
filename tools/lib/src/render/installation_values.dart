import 'dart:io';

import 'package:path/path.dart' as p;

import '../installation.dart';

/// The values an installation supplies, written where the domain stamp cannot reach them.
///
/// The trunk cannot render on its own, and that is by design rather than a gap: two positions in
/// every stack are installation state, and both stand on an install branch. This writes what an
/// installation would have written into them, so the trunk can be rendered without one existing.
///
/// IT IS WRITTEN AT RUN TIME AND IS NEVER A FILE IN THE TREE. It carries the placeholder domain,
/// and the domain stamp rewrites that literal in every tracked file it does not exclude by class.
/// A fixture kept as `tools/fixtures/profile.yaml` matches none of those exclusions, so generating
/// an installation would rewrite the gate's own fixture to that installation's real domain — and
/// the next render would be measuring a customer.
final class InstallationValues {
  /// A fixture for the cluster reached at [fqdn].
  const InstallationValues({this.fqdn = fixtureFqdn, this.apex = placeholderDomain});

  /// The domain the fixture cluster answers on.
  final String fqdn;

  /// The apex its units sit below.
  final String apex;

  /// Writes the fixture into [directory] and answers with the file.
  File writeInto(Directory directory) {
    final File file = File(p.join(directory.path, 'installation-values.yaml'));
    file.writeAsStringSync(document);
    return file;
  }

  /// The fixture, as YAML.
  ///
  /// Every key is one `cluster/profile.yaml` carries on a branch, and every value is composed from
  /// [fqdn] or [apex], so nothing here names a real installation. `servicesLocal` is all true
  /// because the fixture is a master that also holds the build plane: that is the cluster with the
  /// most templates switched ON, and a render that switched them off would pass over exactly the
  /// manifests only one cluster in an installation ever produces.
  String get document =>
      '''
global:
  domain: $fqdn
  clusterName: m1
  unitApex: $apex
  platformDomain: $apex
  booksBranch: $fqdn
  vaultUrl: https://vault.$fqdn
  tailnetUrl: https://tailnet.$fqdn
  catalogUrl: https://github.com/example-org/tenant-catalog.git
  catalogRepo: example-org/tenant-catalog
  vaultKubernetesAuthPath: kubernetes-m1
  alertRecipients:
    - alerts@$apex
  endpoints:
    registry:
      host: zot.$fqdn
    post:
      url: https://post.$fqdn
  servicesLocal:
    registry: true
    vault: true
    observabilityCentral: true
''';
}
