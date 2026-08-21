/// published-databases — no database this repository runs is reachable from outside the cluster it
/// runs in, and each one's NetworkPolicy still says who inside that cluster may open its port.
///
/// **WHICH OF THE TWO THIS ASSUMES, because the ticket it comes from turned on exactly that
/// question.** A master and its slave are ONE cluster when the slave stands on the master's own
/// server, and TWO when it stands alone on a machine of its own. Both happen — the manager deploys a
/// slave either way — so there is no single answer to write down, and this check assumes NEITHER as
/// a standing fact. It holds the tree to the harder of the two: a database answers inside its own
/// cluster and nowhere else. In the one-cluster case that costs nothing, because the databases are
/// already local to whatever reads them. In the two-cluster case it IS the co-location law — no
/// application has its database in another cluster — and publishing the port is how that law gets
/// broken. One rule covering both cases is why there is no second path here to be told apart.
///
/// **WHAT WAS HERE BEFORE, AND WHY IT IS THE OPPOSITE NOW.** hostyour-cloud#27 gave `apps/mongodb`
/// and `apps/redis` an `IngressRouteTCP` on a plain-TCP entry point and widened both NetworkPolicies
/// to admit the ingress controller, so that a `dbgate` running on the MASTER could dial a SLAVE's
/// databases. This library then held those two halves together: it checked that a published database
/// was admitted through. hostyour-cloud#66 removed the routes and the widening, and moved the
/// browser to the cluster its databases run in (`apps/dbgate`, `runsOn: slave`). The subject is the
/// same and the judgement is inverted — what used to be the missing half of a correct arrangement is
/// now the whole of the fault.
///
/// **THE FOUR FAULTS, AND EVERY ONE OF THEM PRESENTS AS A WORKING DATABASE.** None fails a render, an
/// ArgoCD sync or a connection:
///
///   * A ROUTE. A template of the chart renders an `IngressRouteTCP`, an `IngressRouteUDP` or an
///     `Ingress` over the database's own Service. That object IS the publication: whatever the
///     ingress controller carries on the entry point or the host it names arrives at the database.
///   * THE INGRESS CHART AS A DEPENDENCY. `charts/ingress` renders an Ingress out of a values block,
///     so a database chart that embeds it publishes the port the day somebody writes
///     `ingress.enabled: true` in a values file — with no template in this chart to read and nothing
///     in this directory to notice. That a database chart depends on it at all is the finding.
///   * A POLICY THAT ADMITS THE INGRESS CONTROLLER. The controller's namespace named in a `from:`
///     rule is the second half of a route, and it is a fault on its own with no route beside it: it
///     opens the port to every pod of that namespace, and it is what a route added later needs in
///     order to work without anybody touching the policy again.
///   * NO POLICY AT ALL. A database whose workload no NetworkPolicy of its chart selects is not
///     deny-by-default, so it answers every pod of its cluster. This fault is unchanged from before
///     #66 and is the widest of the four.
///
/// **THE SUBJECT IS DERIVED, NEVER LISTED.** A list of database names written into this file would
/// be a second statement of something the tree already makes: `apps/<name>/app.yaml` names an ArgoCD
/// project, and `argocd/apps/projects.yaml` describes `data` as this platform's stateful data
/// stores. So [databaseProject] is what puts an application in the subject, read out of the manifest
/// rather than out of a name. A database added to that project is judged from the day it is added,
/// and one moved out of it drops out of the count the suite states — which is what makes the drop
/// visible instead of silent.
///
/// **Values are RESOLVED, never assumed.** A policy's admitted namespaces and ports are written as
/// `{{ .Values.… }}`, and a check that matched the template text would go on passing after the value
/// under it was renamed or emptied. Every one is looked up in the values that fill it.
///
/// **WHAT IT DOES NOT REACH.**
///
///   * WHERE THE NAMESPACE IS DECIDED. `global.ingressNamespace` holds whatever it holds. A rule
///     admitting `traefik-system` while the controller runs in `ingress` reads here as innocent,
///     because the namespace the controller actually runs in is written by `deploy-cluster.yaml` in
///     the installation repository and read by nothing here. A MISNAMED namespace is invisible where
///     the named one is reported. Closing that means reading the program row the way
///     `vault_selector_labels.dart` already reads that repository.
///   * ANOTHER WAY OUT OF THE CLUSTER. What is read is the chart's own templates, its own `file://`
///     dependencies and its own NetworkPolicies. A Service of `type: LoadBalancer` or `NodePort`, a
///     `hostPort` on a container, and a proxy in a THIRD chart forwarding to the database are each a
///     path out of the cluster that nothing here sees.
///   * WHO ELSE THE POLICY ADMITS. Only the ingress controller's namespace is judged. Whether
///     `global.dbConsumerNamespaces` or a consumer label admits somebody who should not reach the
///     port is a different question, and no check of this package holds it.
///   * THE MACHINE. Whether a machine's own firewall leaves a port closed, and whether the ingress
///     controller carries a plain-TCP entry point at all, are facts of an installation. A green run
///     here says the tree asks for no such thing; it says nothing about what a machine already
///     carries.
library;

import 'package:yaml/yaml.dart';

/// The ArgoCD project `apps/<name>/app.yaml` names when the application is one of this platform's
/// stateful data stores. `argocd/apps/projects.yaml` is where that project is described.
const String databaseProject = 'data';

/// The library chart that renders an Ingress out of a values block, as a path relative to the
/// repository root.
const String ingressChart = 'charts/ingress';

/// The kinds of object that carry a port or a host out of the cluster a chart renders into.
const Set<String> routeKinds = <String>{'IngressRouteTCP', 'IngressRouteUDP', 'Ingress'};

/// A document a database chart renders that would carry its port out of the cluster.
final class RouteDocument {
  /// Records that the template at [where] renders a [kind] naming [sendsTo].
  const RouteDocument({required this.kind, required this.where, required this.sendsTo});

  /// The object kind, as the template writes it.
  final String kind;

  /// The template, as a path relative to the repository — the file somebody opens.
  final String where;

  /// The Service or host it names, as written. Templated in the environment, so it is printed and
  /// never compared.
  final String sendsTo;
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

  /// Whether this rule admits [namespace], on whatever port.
  bool admits(String namespace) => namespaces.contains(namespace);

  /// The ports this rule admits, in the words a finding prints.
  String get reach => allPorts ? 'every port' : (ports.toList()..sort()).join(', ');
}

/// A NetworkPolicy of an app, resolved down to what it selects and what it admits.
final class PolicyDocument {
  /// Records a policy selecting [selects] — null for `podSelector: {}`, which is every pod of the
  /// namespace — and carrying [rules].
  const PolicyDocument({required this.selects, required this.rules});

  /// The `app.kubernetes.io/name` its podSelector matches, or null where it selects every pod.
  final String? selects;

  /// Its ingress rules.
  final List<PolicyRule> rules;

  /// Whether this policy covers the workload of the app called [app].
  bool covers(String app) => selects == null || selects == app;
}

/// One application under `apps/` that runs a database, as far as leaving its cluster goes.
final class DatabaseApp {
  /// Records that [app] renders [routes], depends on [dependencies] and carries [policies].
  const DatabaseApp({
    required this.app,
    required this.routes,
    required this.dependencies,
    required this.policies,
  });

  /// The directory name under `apps/`, which is also the `app.kubernetes.io/name` its workload
  /// carries.
  final String app;

  /// Every route document its own templates render.
  final List<RouteDocument> routes;

  /// The chart directories its `Chart.yaml` depends on through `file://`, relative to the
  /// repository root.
  final Set<String> dependencies;

  /// Every NetworkPolicy its own templates render.
  final List<PolicyDocument> policies;
}

/// Something wrong with what a database chart exposes.
sealed class ExposureFinding {
  /// The app the finding is about.
  String get app;
}

/// A database chart rendering a route out of its cluster.
final class PublishedDatabase implements ExposureFinding {
  /// Records that [app] renders [route].
  const PublishedDatabase(this.app, this.route);

  @override
  final String app;

  /// The document that publishes it.
  final RouteDocument route;

  @override
  String toString() =>
      '${route.where} renders a document of kind ${route.kind} naming ${route.sendsTo} — that '
      'object publishes '
      'apps/$app outside the cluster it runs in, and no application of this platform reaches a '
      'database in another cluster: whatever reads it belongs beside it';
}

/// A database chart that embeds the chart which renders an Ingress out of values.
final class EmbeddedIngressChart implements ExposureFinding {
  /// Records that [app] depends on [chart].
  const EmbeddedIngressChart(this.app, this.chart);

  @override
  final String app;

  /// The dependency, as a path relative to the repository.
  final String chart;

  @override
  String toString() =>
      'apps/$app/Chart.yaml depends on $chart, which renders an Ingress out of a values block — so '
      'this database is published the day somebody writes `ingress.enabled: true` in one of its '
      'values files, with no template in this chart to read and nothing here to report it';
}

/// A database whose policy admits the ingress controller.
final class AdmittedController implements ExposureFinding {
  /// Records that a rule of [app]'s policies admits [namespace] on [reach].
  const AdmittedController(this.app, this.namespace, this.reach);

  @override
  final String app;

  /// The namespace the ingress controller runs in.
  final String namespace;

  /// The ports that rule admits it on.
  final String reach;

  @override
  String toString() =>
      'apps/$app has a NetworkPolicy rule admitting namespace "$namespace" on $reach — that is the '
      'ingress controller, the one workload that opens a connection arriving from outside this '
      'cluster, so the rule is half of a publication whether or not a route stands beside it today';
}

/// A database no NetworkPolicy of its app covers.
final class UnpolicedDatabase implements ExposureFinding {
  /// Records that nothing policies the workload of [app].
  const UnpolicedDatabase(this.app);

  @override
  final String app;

  @override
  String toString() =>
      'apps/$app runs a database and no NetworkPolicy of that chart selects its workload — nothing '
      'is dropped, so the port answers every pod of the cluster, and it presents as a database that '
      'works';
}

/// Everything by which [apps] would take a database out of its own cluster, given the ingress
/// controller runs in [ingressNamespace].
List<ExposureFinding> auditPublishedDatabases({
  required List<DatabaseApp> apps,
  required String ingressNamespace,
}) {
  final List<ExposureFinding> found = <ExposureFinding>[];
  for (final DatabaseApp each in apps) {
    for (final RouteDocument route in each.routes) {
      found.add(PublishedDatabase(each.app, route));
    }
    if (each.dependencies.contains(ingressChart)) {
      found.add(EmbeddedIngressChart(each.app, ingressChart));
    }

    final List<PolicyDocument> covering = <PolicyDocument>[
      for (final PolicyDocument policy in each.policies)
        if (policy.covers(each.app)) policy,
    ];
    if (covering.isEmpty) {
      found.add(UnpolicedDatabase(each.app));
      continue;
    }
    for (final PolicyDocument policy in covering) {
      for (final PolicyRule rule in policy.rules) {
        if (rule.admits(ingressNamespace)) {
          found.add(AdmittedController(each.app, ingressNamespace, rule.reach));
        }
      }
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

final RegExp _kindLine = RegExp(r'^kind:\s*(\S+)\s*$', multiLine: true);
final RegExp _routeTarget = RegExp(r'^\s*-?\s*(?:name|host):\s*(\S.*)$');
final RegExp _documentBreak = RegExp(r'^---\s*$', multiLine: true);

/// The route documents [template], standing at [where], renders.
///
/// A template file renders more than one document where it carries `---`, so each is read on its
/// own. What is reported is the KIND and the first `name:` or `host:` under it: a reader opens the
/// file by the object, not by the value that filled it.
List<RouteDocument> routeDocumentsIn({required String where, required String template}) {
  final List<RouteDocument> found = <RouteDocument>[];
  for (final String document in template.split(_documentBreak)) {
    final RegExpMatch? kind = _kindLine.firstMatch(document);
    if (kind == null || !routeKinds.contains(kind.group(1))) {
      continue;
    }
    String sendsTo = '';
    for (final String line in document.split('\n')) {
      if (line.trim().startsWith('#')) {
        continue;
      }
      if (_routeTarget.firstMatch(line) case final RegExpMatch target when sendsTo.isEmpty) {
        sendsTo = target.group(1)!.trim();
      }
    }
    found.add(
      RouteDocument(kind: kind.group(1)!, where: where, sendsTo: sendsTo.isEmpty ? '?' : sendsTo),
    );
  }
  return found;
}

final RegExp _fileDependency = RegExp(r'repository:\s*file://(\S+)');

/// The chart directories [chart] depends on through `file://`, as paths relative to the repository
/// root, given the chart itself stands at [base] — `apps/mongodb`.
Set<String> fileDependenciesIn({required String base, required String chart}) => <String>{
  for (final RegExpMatch each in _fileDependency.allMatches(chart))
    _normalize(base, each.group(1)!),
};

String _normalize(String base, String relative) {
  final List<String> parts = base.split('/');
  for (final String segment in relative.split('/')) {
    if (segment == '..') {
      if (parts.isNotEmpty) {
        parts.removeLast();
      }
    } else if (segment != '.' && segment.isNotEmpty) {
      parts.add(segment);
    }
  }
  return parts.join('/');
}

final RegExp _rangeOpen = RegExp(r'\{\{-?\s*range\s+\.Values\.([A-Za-z0-9_.-]+)\s*-?\}\}');
final RegExp _rangeClose = RegExp(r'\{\{-?\s*end\s*-?\}\}');
final RegExp _selectedName = RegExp(r'^\s*kubernetes\.io/metadata\.name:\s*(\S.*)$');
final RegExp _appNameLabel = RegExp(r'^\s*app\.kubernetes\.io/name:\s*(\S.*)$');
final RegExp _portValue = RegExp(r'^\s*-?\s*port:\s*(\S.*?)\s*$');

/// The policy [template] declares, resolved against [values], or null where it declares none.
///
/// **A namespace written inside a `range` is resolved through the range, not passed over.** The two
/// DB policies admit their platform consumers by iterating a list in the values, so a reader that
/// only understood a literal would report a policy admitting somebody through that list as
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
      if (_portValue.firstMatch(line) case final RegExpMatch written) {
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
