/// published-databases — every database this repository publishes outside its own cluster is
/// admitted through by its own NetworkPolicy, on the port the route sends to, and no two of them
/// stand on one entry point.
///
/// **What is being held together, and why neither half can be trusted alone.** A database leaves
/// its cluster through two objects that know nothing about each other. The IngressRouteTCP
/// (`apps/<name>/templates/ingressroutetcp.yaml`) tells the ingress controller which Service a
/// plain-TCP entry point belongs to. The NetworkPolicy beside it decides whether the connection the
/// controller then opens is allowed to arrive at all: a policy that selects a pod makes that pod
/// deny-by-default, so the controller's own namespace has to be named in it or Calico drops the
/// packet.
///
/// **THE THREE FAILURES LOOK IDENTICAL FROM THE CLIENT'S SIDE, and that is the whole reason this
/// exists.** A client that cannot connect learns nothing about which of them it met:
///
///   * the policy names the controller's namespace nowhere — the route is live and the packet is
///     dropped by the network. NAMED NOWHERE and MISNAMED are not the same case, and only the first
///     is seen: see "What it CANNOT reach" below;
///   * there is no policy at all — nothing is dropped, and the database that was reachable only
///     from its own cluster is now reachable from every pod in it as well as from the entry point;
///   * no route was rendered — the entry point carries nothing.
///
/// The first and the third both present as a closed port; the second presents as a working
/// database and is the dangerous one. So the check reports each of them in its own words, and the
/// finding names the file to open rather than the symptom.
///
/// **WHAT IT DOES NOT REACH, named one by one rather than counted.** The entry point itself is static
/// configuration of the ingress controller — an argument on the controller's container and the port
/// it publishes on the machine — written by the deploy program of the installation repository and
/// by nothing here. So this check cannot say that the entry point a route names exists, that its
/// address is the machine's tailnet address, or that the machine's firewall leaves the port closed
/// to the public address. Those three are outside this tree, and a green run here says nothing
/// about them.
///
/// **Nor can it say the admitted namespace is the RIGHT one.** A policy admitting
/// `global.ingressNamespace` passes whatever that value holds — set it to `traefik-system` and this
/// check stays green, because the namespace the controller actually runs in is written by
/// `deploy-cluster.yaml` in the installation repository and read by nothing here. So a MISNAMED
/// namespace is invisible where a MISSING one is reported. Closing that means reading the program
/// row the way `vault_selector_labels.dart` already reads that repository.
///
/// **Values are RESOLVED, never assumed.** A route's entry point, its port and a policy's admitted
/// namespaces are written as `{{ .Values.… }}`, and a check that matched the template text would go
/// on passing after the value under it was renamed or emptied. Every one of them is looked up in
/// the values that fill it, and a reference that resolves to nothing is a finding rather than a
/// pass.
library;

import 'package:yaml/yaml.dart';

/// A database an `apps/<name>` chart publishes outside its cluster.
final class PublishedRoute {
  /// Records that the app routes [service] on [port] from entry point [entryPoint].
  const PublishedRoute({required this.entryPoint, required this.service, required this.port});

  /// The ingress controller's entry point the route stands on, or null where the value that names
  /// it resolves to nothing.
  final String? entryPoint;

  /// The Service the route sends to, as the template writes it. Templated in the environment, so it
  /// is never compared — it is printed, because a route that resolves to nothing is opened by
  /// finding the Service it was meant to reach.
  final String service;

  /// The port the route sends to, or null where the value that names it resolves to nothing.
  final int? port;
}

/// One `from:` rule of a NetworkPolicy, resolved.
final class PolicyRule {
  /// Records a rule admitting [namespaces] on [ports], where [allPorts] says the rule named none
  /// and therefore admits every port of the pods it covers.
  const PolicyRule({required this.namespaces, required this.ports, required this.allPorts});

  /// The namespaces the rule admits by `kubernetes.io/metadata.name`.
  final Set<String> namespaces;

  /// The ports it admits them on.
  final Set<int> ports;

  /// Whether the rule named no ports at all, which admits every port.
  final bool allPorts;

  /// Whether this rule admits [namespace] on [port].
  bool admits(String namespace, int? port) =>
      namespaces.contains(namespace) && (allPorts || port == null || ports.contains(port));
}

/// A NetworkPolicy of an app, resolved down to what it selects and what it admits.
final class PolicyDocument {
  /// Records a policy selecting [selects] — empty for `podSelector: {}`, which is every pod of the
  /// namespace — and carrying [rules].
  const PolicyDocument({required this.selects, required this.rules});

  /// The `app.kubernetes.io/name` its podSelector matches, or null where it selects every pod.
  final String? selects;

  /// Its ingress rules.
  final List<PolicyRule> rules;

  /// Whether this policy covers the workload of the app called [app].
  bool covers(String app) => selects == null || selects == app;
}

/// One application under `apps/`, as far as publishing a database goes.
final class PublishedApp {
  /// Records that [app] carries [route] and [policies].
  const PublishedApp({required this.app, required this.route, required this.policies});

  /// The directory name under `apps/`, which is also the `app.kubernetes.io/name` its workload
  /// carries.
  final String app;

  /// The route it publishes, or null where it publishes none.
  final PublishedRoute? route;

  /// Every NetworkPolicy the app renders.
  final List<PolicyDocument> policies;
}

/// Something wrong with what an app publishes.
sealed class ExposureFinding {
  /// The app the finding is about.
  String get app;
}

/// A published database no NetworkPolicy of its app covers.
final class UnpolicedDatabase implements ExposureFinding {
  /// Records that nothing policies the workload of [app].
  const UnpolicedDatabase(this.app);

  @override
  final String app;

  @override
  String toString() =>
      'apps/$app publishes its database on an entry point and no NetworkPolicy of that chart '
      'selects its workload — nothing is dropped, so the port answers, and it answers every pod of '
      'the cluster as well as the entry point';
}

/// A published database whose policy does not let the ingress controller through.
final class UnadmittedController implements ExposureFinding {
  /// Records that no rule of [app]'s policies admits [namespace] on [port].
  const UnadmittedController(this.app, this.namespace, this.port);

  @override
  final String app;

  /// The namespace the ingress controller runs in.
  final String namespace;

  /// The port the route sends to.
  final int? port;

  @override
  String toString() =>
      'apps/$app routes its database from an entry point, and no NetworkPolicy rule of that chart '
      'admits namespace "$namespace" on port ${port ?? "(unresolved)"} — the connection the '
      'controller opens is dropped by Calico, which from the client\'s side is indistinguishable '
      'from an entry point nobody declared';
}

/// A route whose entry point or port resolves to nothing.
final class UnresolvedRoute implements ExposureFinding {
  /// Records that [field] of [app]'s route to [service] resolves to nothing.
  const UnresolvedRoute(this.app, this.field, this.service);

  @override
  final String app;

  /// Which half of the route could not be resolved.
  final String field;

  /// The Service the route was meant to reach, which is where a reader opens the file.
  final String service;

  @override
  String toString() =>
      'apps/$app writes an IngressRouteTCP to $service whose $field resolves to nothing in the '
      'values that fill it — the controller renders the router with an empty $field and drops it, '
      'saying so in its own log and nowhere else';
}

/// Two apps standing on one entry point.
final class SharedEntryPoint implements ExposureFinding {
  /// Records that [app] and [other] both route from [entryPoint].
  const SharedEntryPoint(this.app, this.other, this.entryPoint);

  @override
  final String app;

  /// The other app on the same entry point.
  final String other;

  /// The entry point both name.
  final String entryPoint;

  @override
  String toString() =>
      'apps/$app and apps/$other both route from entry point "$entryPoint" — an entry point is one '
      'port on the machine, and a plain-TCP router matching HostSNI(`*`) matches every connection '
      'that arrives on it, so which of the two databases a client reaches is not decided anywhere';
}

/// Everything wrong with what [apps] publish, given the ingress controller runs in
/// [ingressNamespace].
///
/// An app that publishes nothing is judged on nothing: this check is about the second half of a
/// route, and an app with no route has no second half to be missing.
List<ExposureFinding> auditPublishedDatabases({
  required List<PublishedApp> apps,
  required String ingressNamespace,
}) {
  final List<ExposureFinding> found = <ExposureFinding>[];
  final Map<String, String> byEntryPoint = <String, String>{};
  for (final PublishedApp each in apps) {
    final PublishedRoute? route = each.route;
    if (route == null) {
      continue;
    }
    if (route.entryPoint == null || route.entryPoint!.isEmpty) {
      found.add(UnresolvedRoute(each.app, 'entry point', route.service));
    } else if (byEntryPoint[route.entryPoint!] case final String other) {
      found.add(SharedEntryPoint(each.app, other, route.entryPoint!));
    } else {
      byEntryPoint[route.entryPoint!] = each.app;
    }
    if (route.port == null) {
      found.add(UnresolvedRoute(each.app, 'port', route.service));
    }

    final List<PolicyDocument> covering = <PolicyDocument>[
      for (final PolicyDocument policy in each.policies)
        if (policy.covers(each.app)) policy,
    ];
    if (covering.isEmpty) {
      found.add(UnpolicedDatabase(each.app));
      continue;
    }
    final bool admitted = covering.any(
      (PolicyDocument policy) =>
          policy.rules.any((PolicyRule rule) => rule.admits(ingressNamespace, route.port)),
    );
    if (!admitted) {
      found.add(UnadmittedController(each.app, ingressNamespace, route.port));
    }
  }
  return found;
}

final RegExp _valueReference = RegExp(
  r'^\{\{-?\s*\.Values\.([A-Za-z0-9_.-]+)\s*(?:\|[^}]*?)?-?\}\}$',
);

/// What [written] stands for, looked up in [values] where it is a `{{ .Values.… }}` reference.
///
/// Answers null for anything else that is templated — a range variable, a composed string, a
/// function call. Null means "this tree cannot say", and every caller decides for itself whether
/// that is a finding or something to pass over; nothing here turns it into a value.
Object? resolveValue(String written, Map<String, Object?> values) {
  final String bare = _unquote(written.trim());
  if (!bare.contains('{{')) {
    return bare;
  }
  final RegExpMatch? reference = _valueReference.firstMatch(bare);
  if (reference == null) {
    return null;
  }
  Object? at = values;
  for (final String segment in reference.group(1)!.split('.')) {
    if (at is Map) {
      at = at[segment];
    } else {
      return null;
    }
  }
  return at is YamlList ? at.toList() : at;
}

String _unquote(String written) {
  if (written.length > 1 &&
      (written.startsWith('"') && written.endsWith('"') ||
          written.startsWith("'") && written.endsWith("'"))) {
    return written.substring(1, written.length - 1);
  }
  return written;
}

int _indent(String line) => line.length - line.trimLeft().length;

final RegExp _entryPointItem = RegExp(r'^\s*-\s*(\S.*)$');
final RegExp _serviceName = RegExp(r'^\s*-?\s*name:\s*(\S.*)$');
final RegExp _servicePort = RegExp(r'^\s*-?\s*port:\s*(\S.*?)\s*$');

/// The route [template] declares, resolved against [values], or null where it declares none.
///
/// [values] is the app's own values with the platform `global:` block folded in, because a template
/// reads both through one `.Values`.
PublishedRoute? routeIn({required String template, required Map<String, Object?> values}) {
  if (!template.contains('kind: IngressRouteTCP')) {
    return null;
  }
  final List<String> lines = template.split('\n');

  String? entryPoint;
  for (int i = 0; i < lines.length; i++) {
    if (lines[i].trimRight().endsWith('entryPoints:')) {
      final RegExpMatch? item = i + 1 < lines.length
          ? _entryPointItem.firstMatch(lines[i + 1])
          : null;
      if (item != null) {
        final Object? resolved = resolveValue(item.group(1)!, values);
        entryPoint = resolved is String ? resolved : null;
      }
      break;
    }
  }

  String service = '';
  int? port;
  for (int i = 0; i < lines.length; i++) {
    if (!lines[i].trimRight().endsWith('services:')) {
      continue;
    }
    final int block = _indent(lines[i]);
    for (
      int j = i + 1;
      j < lines.length && (lines[j].trim().isEmpty || _indent(lines[j]) > block);
      j++
    ) {
      if (lines[j].trim().startsWith('#')) {
        continue;
      }
      if (_serviceName.firstMatch(lines[j]) case final RegExpMatch name when service.isEmpty) {
        service = name.group(1)!.trim();
      }
      if (_servicePort.firstMatch(lines[j]) case final RegExpMatch written when port == null) {
        final Object? resolved = resolveValue(written.group(1)!, values);
        port = resolved is int ? resolved : int.tryParse('$resolved');
      }
    }
    break;
  }
  return PublishedRoute(entryPoint: entryPoint, service: service, port: port);
}

final RegExp _rangeOpen = RegExp(r'\{\{-?\s*range\s+\.Values\.([A-Za-z0-9_.-]+)\s*-?\}\}');
final RegExp _rangeClose = RegExp(r'\{\{-?\s*end\s*-?\}\}');
final RegExp _selectedName = RegExp(r'^\s*kubernetes\.io/metadata\.name:\s*(\S.*)$');
final RegExp _appNameLabel = RegExp(r'^\s*app\.kubernetes\.io/name:\s*(\S.*)$');

/// The policy [template] declares, resolved against [values], or null where it declares none.
///
/// **A namespace written inside a `range` is resolved through the range, not passed over.** The two
/// DB policies admit their platform consumers by iterating a list in the values, so a reader that
/// only understood a literal would report a policy that admits the controller through that list as
/// admitting nothing — a false refusal, which costs the same trust as a false pass.
PolicyDocument? policyIn({required String template, required Map<String, Object?> values}) {
  if (!template.contains('kind: NetworkPolicy')) {
    return null;
  }
  final List<String> lines = template.split('\n');

  String? selects;
  for (int i = 0; i < lines.length; i++) {
    if (!lines[i].trimRight().endsWith('podSelector:')) {
      continue;
    }
    final int block = _indent(lines[i]);
    for (
      int j = i + 1;
      j < lines.length && (lines[j].trim().isEmpty || _indent(lines[j]) > block);
      j++
    ) {
      if (_appNameLabel.firstMatch(lines[j]) case final RegExpMatch label) {
        final Object? resolved = resolveValue(label.group(1)!, values);
        selects = resolved is String ? resolved : null;
      }
    }
    break;
  }

  final List<PolicyRule> rules = <PolicyRule>[];
  for (int i = 0; i < lines.length; i++) {
    if (!lines[i].trimRight().endsWith('ingress:')) {
      continue;
    }
    final int block = _indent(lines[i]);
    List<String> rule = <String>[];
    int? itemIndent;
    for (
      int j = i + 1;
      j <= lines.length &&
          (j == lines.length || lines[j].trim().isEmpty || _indent(lines[j]) > block);
      j++
    ) {
      final bool ends = j == lines.length;
      final bool starts =
          !ends &&
          lines[j].trim().startsWith('-') &&
          (itemIndent == null || _indent(lines[j]) == itemIndent);
      if ((ends || starts) && rule.isNotEmpty) {
        rules.add(_ruleOf(rule, values));
        rule = <String>[];
      }
      if (ends) {
        break;
      }
      if (starts) {
        itemIndent = _indent(lines[j]);
      }
      rule.add(lines[j]);
    }
    if (rule.isNotEmpty) {
      rules.add(_ruleOf(rule, values));
    }
    break;
  }
  return PolicyDocument(selects: selects, rules: rules);
}

PolicyRule _ruleOf(List<String> lines, Map<String, Object?> values) {
  final Set<String> namespaces = <String>{};
  final Set<int> ports = <int>{};
  bool inPorts = false;
  int? portsIndent;
  final List<String> ranges = <String>[];

  for (final String line in lines) {
    if (line.trim().startsWith('#')) {
      continue;
    }
    if (_rangeOpen.firstMatch(line) case final RegExpMatch open) {
      ranges.add(open.group(1)!);
    }
    if (_rangeClose.hasMatch(line) && ranges.isNotEmpty) {
      ranges.removeLast();
    }
    if (line.trimRight().endsWith('ports:')) {
      inPorts = true;
      portsIndent = _indent(line);
      continue;
    }
    if (inPorts && line.trim().isNotEmpty && _indent(line) <= portsIndent!) {
      inPorts = false;
    }
    if (inPorts) {
      if (_servicePort.firstMatch(line) case final RegExpMatch written) {
        final Object? resolved = resolveValue(written.group(1)!, values);
        final int? port = resolved is int ? resolved : int.tryParse('$resolved');
        if (port != null) {
          ports.add(port);
        }
      }
      continue;
    }
    if (_selectedName.firstMatch(line) case final RegExpMatch selected) {
      final Object? resolved = resolveValue(selected.group(1)!, values);
      if (resolved is String) {
        namespaces.add(resolved);
      } else if (ranges.isNotEmpty) {
        final Object? list = resolveValue('{{ .Values.${ranges.last} }}', values);
        if (list is List) {
          namespaces.addAll(list.whereType<String>());
        }
      }
    }
  }
  return PolicyRule(namespaces: namespaces, ports: ports, allPorts: ports.isEmpty);
}
