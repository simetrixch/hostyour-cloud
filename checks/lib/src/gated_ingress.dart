/// gated-ingress — every Ingress an application of this repository renders names a Traefik
/// Middleware that is rendered into the cluster that application itself stands in, and an
/// application whose own pod asks nobody who is calling names one at all.
///
/// **WHAT A MIDDLEWARE REFERENCE IS WORTH WHEN IT RESOLVES TO NOTHING.** An Ingress puts a gate in
/// front of itself by naming one in an annotation —
/// `traefik.ingress.kubernetes.io/router.middlewares: <namespace>-<name>@kubernetescrd`. Traefik
/// resolves that name through its kubernetescrd provider, and a name that resolves to nothing does
/// not fail the render, the ArgoCD sync or the certificate: Traefik DROPS the route and says so in
/// its own log and nowhere else. So the two halves — an Ingress and the Middleware its annotation
/// names — are one statement, and either half alone publishes a workload with nothing in front of
/// it.
///
/// **WHICH CLUSTER, AND THAT IS THE WHOLE DIFFICULTY.** A middleware is an object in ONE cluster.
/// This platform renders them two ways and the two stand in different places:
///
///   * `charts/middleware` renders a namespace-local basicAuth Middleware out of a values block, so
///     it stands in the namespace of the application that embeds it and on whichever cluster that
///     application's `runsOn` places it. `apps/observability` uses it exactly so — the
///     `push-auth-middleware` block names `obs-push-auth`, and both push Ingresses beside it name
///     `observability-obs-push-auth@kubernetescrd`.
///   * a manifest under `bootstrap/` is applied by a step of an installation program, and the
///     program's own `roles:` decide which clusters get it. `bootstrap/idp/middleware-forwardauth.yaml`
///     is applied by `deploy-gitops`, which declares `roles: [master]` — so `idp-forwardauth@kubernetescrd`
///     exists on a master and on no slave.
///
/// hostyour-cloud#66 moved `apps/dbgate` into the cluster whose databases it opens, which for a
/// slave is a cluster with no `idp` namespace. Turning that Ingress on there would not produce a
/// gated browser; it would produce an ungated one. A check that knew only the forwardAuth mechanism
/// would be wrong the other way round and refuse `apps/observability`, whose gate is correct and
/// cluster-local, so BOTH mechanisms are read.
///
/// **AN APPLICATION THAT SWITCHES ITS OWN AUTHENTICATION OFF IS HELD HARDER.** `apps/dbgate` runs
/// with [skipAllAuthVariable] set, which is DBGate's own switch for "ask nobody" — so what stands in
/// front of it IS the gate and there is nothing else. For such an application an Ingress naming no
/// middleware at all is the same defect as one naming a middleware that is elsewhere, and it is
/// reported as its own finding. Every other Ingress of this tree is answered by the workload behind
/// it — `apps/manager` has a login, `apps/registry` has zot's accessControl — and naming no
/// middleware there is not a fault, which is why the subject is read out of the pod's own
/// environment rather than out of a list of applications written here.
///
/// **WHAT IT DOES NOT REACH.**
///
///   * ONLY `apps/`, and only the Ingress `charts/ingress` renders out of a values block. An Ingress
///     a chart's own template renders, and every Ingress of `slaves/`, `units/`, `argocd/` and
///     `bootstrap/`, is read by nothing here. An `IngressRoute` — Traefik's own CRD, which
///     `bootstrap/vault/ingressroute.yaml` uses — carries its middlewares in `spec` rather than in an
///     annotation and is out of the subject too.
///   * WHETHER THE CHART RENDERS AT ALL. An `enabled` or a chart-level `condition:` behind which a
///     values block stands is a value a render resolves, and this reads the values as they stand on
///     disk. An Ingress one per-stage file turns on and another turns off is judged as rendered,
///     which is the safe direction; a middleware whose `condition:` is false on a given installation
///     is read as rendered, which is not, and `apps/observability` is where that matters — its two
///     push Ingresses and the middleware in front of them carry the SAME condition, so they stand or
///     fall together.
///   * WHETHER A PROGRAM'S STEP RAN. A manifest a step applies `when:` some condition holds is read
///     here as applied, and `bootstrap/idp/middleware-forwardauth.yaml` is exactly that — it is
///     applied `when: [idp_enabled]`. So a master with the identity provider switched off reads here
///     as a master that carries the middleware.
///   * WHAT THE MIDDLEWARE DOES. That an object of kind `Middleware` exists under the name an
///     annotation gives is all that is held. Whether its `forwardAuth` address answers, whether the
///     Secret its `basicAuth` names is ever materialized, and whether the session cookie an identity
///     provider issues is scoped to the host in front of it, are each a way a resolved middleware
///     still admits everybody, and no check of this package holds any of them.
///   * A NAME A RELEASE COMPOSES. `charts/middleware` names its object through `common.fullname`,
///     which is the release name unless the values carry a `fullnameOverride` — and a release of this
///     platform is `<app>-<stage>`, so the name differs per stage. Such a render is recorded with no
///     name and answers no reference, because `charts/ingress` passes its `annotations` through
///     verbatim rather than through `tpl` and an annotation of this tree is therefore always a
///     literal. It is NAMED in the finding of any reference nothing answers, so a near miss reads as
///     one.
///   * THE OTHER PROVIDERS. Only a reference ending in [crdProvider] is held. A middleware Traefik
///     carries from its static configuration or from another provider is named by nothing this
///     repository renders, and such a reference is passed over by name rather than reported.
library;

import 'external_secret_keys.dart' show commentFreeLines;
import 'external_secret_reach.dart' show ApplicationPlacement, valuesKeysFor;
import 'published_databases.dart' show ingressChart;

/// The chart an application embeds to get a namespace-local Traefik Middleware out of a values
/// block, as a path relative to the repository root.
const String middlewareChart = 'charts/middleware';

/// The values key `charts/ingress` reads its own block under, as `charts/ingress/values.yaml` opens
/// with.
const String ingressValuesRoot = 'ingress';

/// The values key `charts/middleware` reads its own block under, as `charts/middleware/values.yaml`
/// opens with.
const String middlewareValuesRoot = 'middleware';

/// The annotation an Ingress puts a Traefik Middleware in front of itself with.
const String middlewareAnnotation = 'traefik.ingress.kubernetes.io/router.middlewares';

/// How a reference names the provider that resolves it — the Kubernetes CRD provider, which is the
/// one that resolves a `Middleware` object of a cluster.
const String crdProvider = '@kubernetescrd';

/// The environment variable an application sets to switch its own authentication off.
///
/// DBGate's own name for it, written in `apps/dbgate/values-common.yaml`. An application carrying it
/// asks nobody who is calling, so whatever stands in front of its Ingress is the only gate there is.
const String skipAllAuthVariable = 'SKIP_ALL_AUTH';

/// The role of the cluster an installation is installed on first, as a program's `roles:` writes it.
const String masterRole = 'master';

/// The role of a cluster a master registers, as a program's `roles:` writes it.
const String slaveRole = 'slave';

// ---------------------------------------------------------------------------------------------
// The installation's side: which clusters carry a manifest of `bootstrap/`.
// ---------------------------------------------------------------------------------------------

/// One installation program: the cluster roles it runs for, and the manifests its steps apply.
final class ProgramManifests {
  /// Records that [program] runs for [roles] and applies [manifests].
  const ProgramManifests({required this.program, required this.roles, required this.manifests});

  /// The program, as a path that names the file somebody has to open.
  final String program;

  /// The cluster roles the program declares it runs for.
  final Set<String> roles;

  /// The manifests its steps apply, as the rows write them — paths into this repository's checkout.
  final Set<String> manifests;
}

/// What the program at [program] applies and where, where [document] is its parsed YAML.
///
/// Every `manifest:` of the document is taken rather than the `manifest:` of one named step kind:
/// which steps apply an object is the program's own business, and `deploy-gitops` alone applies its
/// manifests through two of them — `kubernetes_object` and `kubernetes_object_irreversible`. A
/// manifest path naming no file of this repository simply answers no middleware, so taking one too
/// many costs nothing and missing one would place a middleware in no cluster at all.
ProgramManifests programManifestsIn({required String program, required Object? document}) {
  final Set<String> manifests = <String>{};
  void walk(Object? node) {
    if (node is Map) {
      if (node['manifest'] case final String found) {
        manifests.add(found);
      }
      for (final Object? value in node.values) {
        walk(value);
      }
    } else if (node is List) {
      for (final Object? value in node) {
        walk(value);
      }
    }
  }

  walk(document);
  final Object? declared = document is Map ? document['roles'] : null;
  return ProgramManifests(
    program: program,
    roles: <String>{
      if (declared is List)
        for (final Object? each in declared)
          if (each is String) each,
    },
    manifests: manifests,
  );
}

/// Which cluster roles each manifest of [programs] is applied for.
///
/// The UNION over the programs applying one manifest, and that is the direction this check needs: a
/// manifest one program applies on a master and another on a slave stands in both, and holding it to
/// the intersection would report a middleware that is there.
Map<String, Set<String>> manifestRolesOf(Iterable<ProgramManifests> programs) {
  final Map<String, Set<String>> roles = <String, Set<String>>{};
  for (final ProgramManifests each in programs) {
    for (final String manifest in each.manifests) {
      roles.putIfAbsent(manifest, () => <String>{}).addAll(each.roles);
    }
  }
  return roles;
}

// ---------------------------------------------------------------------------------------------
// This tree's side: the middlewares it renders and the Ingresses that name them.
// ---------------------------------------------------------------------------------------------

/// One Traefik Middleware object a manifest of `bootstrap/` declares.
final class MiddlewareObject {
  /// Records that [where] declares a Middleware [name] in [namespace].
  const MiddlewareObject({required this.where, required this.namespace, required this.name});

  /// The manifest, as a path relative to the repository — the file somebody opens.
  final String where;

  /// The namespace the object stands in.
  final String namespace;

  /// The object's name, which is the half an annotation writes after the namespace.
  final String name;
}

/// Every Traefik Middleware the manifest [source], standing at [where], declares.
///
/// A document's own `kind:` is read at column zero, the way `external-secret-reach` reads one: a
/// manifest renders several objects separated by `---`, and `bootstrap/vault/ingressroute.yaml`
/// carries a Middleware beside an IngressRoute that REFERENCES it under `spec.routes[].middlewares`.
/// Reading that reference as a second object would place a middleware in a namespace nothing renders
/// one into.
List<MiddlewareObject> middlewareObjectsIn({required String where, required String source}) {
  final List<MiddlewareObject> found = <MiddlewareObject>[];
  for (final List<String> document in _documentsIn(commentFreeLines(source))) {
    if (!document.any((String line) => RegExp(r'^kind:\s*Middleware\s*$').hasMatch(line))) {
      continue;
    }
    final String? namespace = _metadataOf(document, 'namespace');
    final String? name = _metadataOf(document, 'name');
    if (namespace == null || name == null) {
      continue;
    }
    found.add(MiddlewareObject(where: where, namespace: namespace, name: name));
  }
  return found;
}

/// One Traefik Middleware this platform renders, and the clusters it stands in.
final class RenderedMiddleware {
  /// Records that [where] renders a Middleware [name] in [namespace], on a master where [onAMaster]
  /// and on a slave where [onASlave].
  const RenderedMiddleware({
    required this.where,
    required this.namespace,
    required this.name,
    required this.onAMaster,
    required this.onASlave,
  });

  /// The file somebody has to open, as a path relative to the repository.
  final String where;

  /// The namespace the object stands in.
  final String namespace;

  /// The object's name, or null where a release composes it and no `fullnameOverride` pins it.
  final String? name;

  /// Whether it stands in a cluster whose role is [masterRole].
  final bool onAMaster;

  /// Whether it stands in a cluster whose role is [slaveRole].
  final bool onASlave;

  /// The reference an Ingress annotation names this object by, or null where its name is composed.
  String? get reference => name == null ? null : '$namespace-$name$crdProvider';

  /// The clusters it stands in, in the words a finding prints.
  String get sides {
    if (onAMaster && onASlave) {
      return 'a master and a slave';
    }
    if (onAMaster) {
      return 'a master';
    }
    return onASlave ? 'a slave' : 'no cluster at all';
  }

  /// The one line a finding says about it.
  @override
  String toString() =>
      '$where renders ${name == null ? 'a Middleware in namespace "$namespace" whose name the '
                'release composes' : '"$reference"'} on $sides';
}

/// The middleware [object] is, given [roles] are the cluster roles the manifest declaring it is
/// applied for.
RenderedMiddleware placedMiddleware({
  required MiddlewareObject object,
  required Set<String> roles,
}) => RenderedMiddleware(
  where: object.where,
  namespace: object.namespace,
  name: object.name,
  onAMaster: roles.contains(masterRole),
  onASlave: roles.contains(slaveRole),
);

/// One Ingress an application renders out of a `charts/ingress` values block.
final class RenderedIngress {
  /// Records that the application at [application] renders an Ingress under the values key [key],
  /// stated in [where], naming [middlewares], where [skipsAllAuth] says its own pod asks nobody who
  /// is calling.
  const RenderedIngress({
    required this.where,
    required this.application,
    required this.key,
    required this.middlewares,
    required this.skipsAllAuth,
  });

  /// The files somebody has to open, as paths relative to the repository.
  final String where;

  /// The application directory it belongs to, such as `apps/dbgate`.
  final String application;

  /// The values key the block hangs under, which is the dependency's alias where it carries one.
  final String key;

  /// The middlewares its annotation names, exactly as written.
  final List<String> middlewares;

  /// Whether the application's own pod carries [skipAllAuthVariable].
  final bool skipsAllAuth;
}

/// What one application's files render in front of themselves.
final class GateReading {
  /// Records that an application renders [ingresses] and [middlewares].
  const GateReading({required this.ingresses, required this.middlewares});

  /// The Ingresses it renders that are switched on in at least one of its values files.
  final List<RenderedIngress> ingresses;

  /// The Middlewares it renders, which stand in its own namespace and on its own cluster.
  final List<RenderedMiddleware> middlewares;
}

/// What the files of the application at [application] render, where [files] holds the source of each
/// by its path relative to the repository.
///
/// [files] carries the application's `Chart.yaml` and its values files. The blocks of ONE dependency
/// are merged across the files that layer onto it, for the reason `external-secret-reach` merges
/// them: an application states the switch in `values-common.yaml` and a per-stage file may turn it
/// the other way, and a reading per file would report two Ingresses where the release has one.
///
/// An Ingress switched on in ANY of the files is read as rendered. The per-stage layers of this tree
/// decide a host and an image, not whether a gate is needed, and an Ingress that stands in one stage
/// publishes what it publishes there.
GateReading readApplicationGates({
  required String application,
  required ApplicationPlacement placement,
  required Map<String, String> files,
}) {
  final String chart = files['$application/Chart.yaml'] ?? '';
  final Set<String> ingressKeys = valuesKeysFor(source: chart, chart: ingressChart);
  final Set<String> middlewareKeys = valuesKeysFor(source: chart, chart: middlewareChart);

  final Map<String, _MergedIngress> ingresses = <String, _MergedIngress>{};
  final Map<String, _MergedMiddleware> middlewares = <String, _MergedMiddleware>{
    for (final String key in middlewareKeys) key: _MergedMiddleware(),
  };
  bool skipsAllAuth = false;

  for (final String path in files.keys.toList()..sort()) {
    final List<String> lines = commentFreeLines(files[path]!);
    skipsAllAuth = skipsAllAuth || skipsAllAuthIn(lines);

    for (final String key in ingressKeys) {
      final List<String>? block = _topBlock(lines, key);
      final List<String>? root = block == null ? null : _childBlock(block, ingressValuesRoot);
      if (root == null) {
        continue;
      }
      final _MergedIngress merged = ingresses.putIfAbsent(key, _MergedIngress.new);
      merged.declaredIn.add(path);
      if (_readsAsTrue(_childScalar(root, 'enabled'))) {
        merged.enabled = true;
      }
      final List<String>? annotations = _childBlock(root, 'annotations');
      if (annotations == null) {
        continue;
      }
      if (_childScalar(annotations, middlewareAnnotation) case final String written) {
        merged.references.addAll(referencesIn(written));
      }
    }

    for (final String key in middlewareKeys) {
      final List<String>? block = _topBlock(lines, key);
      if (block == null) {
        continue;
      }
      final _MergedMiddleware merged = middlewares[key]!;
      merged.declaredIn.add(path);
      if (_childScalar(block, 'fullnameOverride') case final String found) {
        merged.name = found;
      }
      final List<String>? root = _childBlock(block, middlewareValuesRoot);
      if (root == null) {
        continue;
      }
      if (_childScalar(root, 'enabled') case final String written) {
        merged.enabled = written == 'true';
      }
    }
  }

  return GateReading(
    ingresses: <RenderedIngress>[
      for (final String key in ingresses.keys.toList()..sort())
        if (ingresses[key]!.enabled)
          RenderedIngress(
            where: ingresses[key]!.where,
            application: application,
            key: key,
            middlewares: ingresses[key]!.references.toList()..sort(),
            skipsAllAuth: skipsAllAuth,
          ),
    ],
    middlewares: <RenderedMiddleware>[
      for (final String key in middlewares.keys.toList()..sort())
        if (middlewares[key]!.enabled)
          RenderedMiddleware(
            where: middlewares[key]!.where.isEmpty
                ? '$application/Chart.yaml'
                : middlewares[key]!.where,
            namespace: placement.namespace,
            name: middlewares[key]!.name,
            onAMaster: placement.onAMaster,
            onASlave: placement.onASlave,
          ),
    ],
  );
}

/// The middlewares the annotation value [written] names.
///
/// Traefik takes a comma-separated list there, so one annotation puts several gates in front of one
/// route and a reader that took the whole value for one name would hold a real reference to nothing.
List<String> referencesIn(String written) => <String>[
  for (final String each in written.split(','))
    if (each.trim() case final String reference)
      if (reference.isNotEmpty) reference,
];

/// Whether [lines] set [skipAllAuthVariable] to true.
///
/// The value beside the name and not the name alone: an application that carries the variable set to
/// anything else has its own authentication on, and reading the name as the switch would hold it to
/// a gate it does not need.
bool skipsAllAuthIn(List<String> lines) {
  for (int i = 0; i < lines.length; i++) {
    if (!RegExp('^\\s*-\\s+name:\\s*$skipAllAuthVariable\\s*\$').hasMatch(lines[i])) {
      continue;
    }
    for (final String line in lines.sublist(i + 1, _blockEnd(lines, i))) {
      if (_scalar(line, 'value') case final String found) {
        return found == 'true';
      }
    }
  }
  return false;
}

/// One `charts/ingress` values block, as the files that layer onto it leave it.
final class _MergedIngress {
  final Set<String> declaredIn = <String>{};
  final Set<String> references = <String>{};
  bool enabled = false;

  String get where => (declaredIn.toList()..sort()).join(', ');
}

/// One `charts/middleware` values block, as the files that layer onto it leave it.
///
/// [enabled] starts true because `charts/middleware/values.yaml` does: an application that embeds
/// the chart and writes no block of its own still renders the object, and starting from false would
/// report a middleware that is there as one that is not.
final class _MergedMiddleware {
  final Set<String> declaredIn = <String>{};
  String? name;
  bool enabled = true;

  String get where => (declaredIn.toList()..sort()).join(', ');
}

// ---------------------------------------------------------------------------------------------
// Holding one side to the other.
// ---------------------------------------------------------------------------------------------

/// One way an Ingress of this repository is published with nothing resolving in front of it.
sealed class GateFinding {
  const GateFinding();

  /// The application directory the finding is about, such as `apps/dbgate`.
  String get application;
}

/// An Ingress naming a middleware nothing of this platform renders.
final class UnrenderedGate extends GateFinding {
  /// Records that [ingress] names [reference] and [rendered] is everything this platform does
  /// render.
  const UnrenderedGate({required this.ingress, required this.reference, required this.rendered});

  /// The Ingress whose gate resolves to nothing.
  final RenderedIngress ingress;

  /// The middleware it names, exactly as the annotation writes it.
  final String reference;

  /// Every Middleware this platform renders, so a near miss reads as one.
  final List<RenderedMiddleware> rendered;

  @override
  String get application => ingress.application;

  /// The one line a refusal says about it.
  @override
  String toString() =>
      '${ingress.where} renders the Ingress "${ingress.key}" naming the middleware "$reference", '
      'and no values block of apps/ and no manifest of bootstrap/ renders a Middleware of that '
      'reference — THE MIDDLEWARE is the half that is missing. Traefik drops a route whose '
      'middleware does not resolve and says so in its own log and nowhere else, so what this '
      'publishes is ${ingress.application} with nothing in front of it. What is rendered is '
      '${rendered.isEmpty ? 'nothing' : rendered.map((RenderedMiddleware each) => each.toString()).join('; ')}';
}

/// An Ingress naming a middleware that is rendered, and not into the cluster the Ingress stands in.
final class GateInAnotherCluster extends GateFinding {
  /// Records that [ingress] names [reference], which [rendered] renders, and that [side] is the
  /// cluster the application runs on where it is not.
  const GateInAnotherCluster({
    required this.ingress,
    required this.reference,
    required this.side,
    required this.rendered,
  });

  /// The Ingress whose gate stands elsewhere.
  final RenderedIngress ingress;

  /// The middleware it names, exactly as the annotation writes it.
  final String reference;

  /// The cluster the application runs on that carries no such object — `a master` or `a slave`.
  final String side;

  /// Where the object it names is rendered, so a reader is told what to move and what to add.
  final List<RenderedMiddleware> rendered;

  @override
  String get application => ingress.application;

  /// The one line a refusal says about it.
  @override
  String toString() =>
      '${ingress.where} renders the Ingress "${ingress.key}" naming the middleware "$reference", '
      'and ${ingress.application} runs on $side, which carries no such object — THE CLUSTER is what '
      'the two halves do not share. The middleware is rendered: '
      '${rendered.map((RenderedMiddleware each) => each.toString()).join('; ')}. A reference that '
      'resolves in one cluster resolves to nothing in another, and Traefik drops the route rather '
      'than refusing it';
}

/// An Ingress on an application that asks nobody who is calling, naming no middleware at all.
final class UngatedIngress extends GateFinding {
  /// Records that [ingress] names no middleware while its own pod carries [skipAllAuthVariable].
  const UngatedIngress({required this.ingress});

  /// The Ingress that publishes a workload with no gate named.
  final RenderedIngress ingress;

  @override
  String get application => ingress.application;

  /// The one line a refusal says about it.
  @override
  String toString() =>
      '${ingress.where} renders the Ingress "${ingress.key}" and its "$middlewareAnnotation" '
      'annotation names nothing, while the pod of ${ingress.application} carries '
      '$skipAllAuthVariable set to true — nothing in that pod asks who is calling, so the gate is '
      'whatever stands in front of it and here that is nothing. THE MIDDLEWARE is the half that is '
      'missing, and no annotation even asks for one';
}

/// What holding this tree's Ingresses to the middlewares of this platform found, and what it could
/// not hold.
final class GateAudit {
  /// Records [findings] over [judged] Ingresses, with [passedOver] saying why a reference was not
  /// held.
  const GateAudit({required this.judged, required this.passedOver, required this.findings});

  /// The Ingresses a verdict was reached on.
  final List<RenderedIngress> judged;

  /// Every reference not held, and the reason, in the words whoever wrote it reads.
  final List<String> passedOver;

  /// Every way an Ingress is published with nothing resolving in front of it.
  final List<GateFinding> findings;
}

/// Holds every Ingress of [ingresses] to [middlewares], given [placements] says which cluster each
/// application stands in.
///
/// A reference is answered per SIDE, never by the union: a middleware rendered on a master answers
/// an Ingress of an application that runs on a master, and the same reference on an application that
/// runs on a slave is answered by nothing. An application whose `runsOn` is `every-cluster` is held
/// to both, which is what `external-secret-reach` does with the same field for the same reason.
GateAudit auditGatedIngress({
  required List<RenderedIngress> ingresses,
  required Map<String, ApplicationPlacement> placements,
  required List<RenderedMiddleware> middlewares,
}) {
  final List<RenderedIngress> judged = <RenderedIngress>[];
  final List<String> passedOver = <String>[];
  final List<GateFinding> found = <GateFinding>[];

  for (final RenderedIngress ingress in ingresses) {
    final ApplicationPlacement placement = placements[ingress.application]!;
    judged.add(ingress);

    if (ingress.middlewares.isEmpty) {
      if (ingress.skipsAllAuth) {
        found.add(UngatedIngress(ingress: ingress));
      }
      continue;
    }

    for (final String reference in ingress.middlewares) {
      if (!reference.endsWith(crdProvider)) {
        passedOver.add(
          '${ingress.where} names the middleware "$reference", which is resolved by a provider '
          'other than $crdProvider — no object of any cluster this repository renders into carries '
          'that name, and what answers it is the ingress controller\'s own configuration',
        );
        continue;
      }
      final List<RenderedMiddleware> named = <RenderedMiddleware>[
        for (final RenderedMiddleware each in middlewares)
          if (each.reference == reference) each,
      ];
      if (named.isEmpty) {
        found.add(UnrenderedGate(ingress: ingress, reference: reference, rendered: middlewares));
        continue;
      }
      if (placement.onAMaster && !named.any((RenderedMiddleware each) => each.onAMaster)) {
        found.add(
          GateInAnotherCluster(
            ingress: ingress,
            reference: reference,
            side: 'a master',
            rendered: named,
          ),
        );
      }
      if (placement.onASlave && !named.any((RenderedMiddleware each) => each.onASlave)) {
        found.add(
          GateInAnotherCluster(
            ingress: ingress,
            reference: reference,
            side: 'a slave',
            rendered: named,
          ),
        );
      }
    }
  }

  return GateAudit(judged: judged, passedOver: passedOver, findings: found);
}

// ---------------------------------------------------------------------------------------------
// Reading a block, a document and a scalar out of files Helm templates.
// ---------------------------------------------------------------------------------------------

/// Whether a values scalar switches something ON, in every spelling helm resolves as true.
///
/// Helm parses values as YAML 1.1, where `True`, `TRUE`, `yes`, `y` and `on` are the same boolean as
/// `true`. A reader that compares against the one lower-case spelling reads an Ingress that RENDERS
/// as one that does not, which is the direction that matters: it would pass over exactly the
/// document it exists to judge.
bool _readsAsTrue(String? scalar) => switch (scalar?.toLowerCase()) {
  'true' || 'yes' || 'y' || 'on' => true,
  _ => false,
};

/// The lines of the block the key [key] opens at column zero in [lines], or null where it opens
/// none.
///
/// At column zero, because a dependency's values hang under a top-level key and nothing else does.
/// `apps/observability` carries an `ingress:` block nested four levels inside the values of a
/// vendored chart, and reading that as this tree's own Ingress would hold a chart nobody here wrote
/// to an annotation nobody here writes.
List<String>? _topBlock(List<String> lines, String key) {
  for (int i = 0; i < lines.length; i++) {
    if (RegExp('^${RegExp.escape(key)}:\\s*\$').hasMatch(lines[i])) {
      return lines.sublist(i + 1, _blockEnd(lines, i));
    }
  }
  return null;
}

/// The lines of the block the DIRECT child [key] of [block] opens, or null where it opens none.
///
/// Direct, and that is what tells `ingress.enabled` from `ingress.tls.enabled`: both are written
/// `enabled:` and one decides whether the object exists while the other decides whether it carries a
/// certificate. `apps/dbgate` has the first false and the second true, so a reader taking any
/// `enabled: true` of the block would read its Ingress as switched on.
List<String>? _childBlock(List<String> block, String key) {
  final int indent = _childIndent(block);
  for (int i = 0; i < block.length; i++) {
    if (_indent(block[i]) != indent) {
      continue;
    }
    if (RegExp('^\\s*${RegExp.escape(key)}:\\s*\$').hasMatch(block[i])) {
      return block.sublist(i + 1, _blockEnd(block, i));
    }
  }
  return null;
}

/// The value the DIRECT child [field] of [block] holds, or null where it holds none.
String? _childScalar(List<String> block, String field) {
  final int indent = _childIndent(block);
  for (final String line in block) {
    if (_indent(line) != indent) {
      continue;
    }
    if (_scalar(line, field) case final String found) {
      return found;
    }
  }
  return null;
}

/// The indentation the direct children of [block] stand at, which is the shallowest one in it.
int _childIndent(List<String> block) {
  int shallowest = -1;
  for (final String line in block) {
    if (line.trim().isEmpty) {
      continue;
    }
    final int indent = _indent(line);
    if (shallowest < 0 || indent < shallowest) {
      shallowest = indent;
    }
  }
  return shallowest;
}

/// The documents [lines] holds, split on the `---` that separates them.
List<List<String>> _documentsIn(List<String> lines) {
  final List<List<String>> documents = <List<String>>[];
  int start = 0;
  for (int i = 0; i <= lines.length; i++) {
    if (i == lines.length || RegExp(r'^---\s*$').hasMatch(lines[i])) {
      documents.add(lines.sublist(start, i));
      start = i + 1;
    }
  }
  return documents;
}

/// The `metadata.<field>` of [document], or null where the block names none.
String? _metadataOf(List<String> document, String field) {
  for (int i = 0; i < document.length; i++) {
    if (!RegExp(r'^metadata:\s*$').hasMatch(document[i])) {
      continue;
    }
    for (final String line in document.sublist(i + 1, _blockEnd(document, i))) {
      if (_scalar(line, field) case final String found) {
        return found;
      }
    }
  }
  return null;
}

/// The value [line] writes for [field], or null where it writes something else or nothing.
String? _scalar(String line, String field) {
  final RegExpMatch? found = RegExp(
    '^\\s*(?:-\\s+)?${RegExp.escape(field)}:\\s*(\\S.*?)\\s*\$',
  ).firstMatch(line);
  if (found == null) {
    return null;
  }
  final String bare = _unquote(found.group(1)!);
  return bare.isEmpty ? null : bare;
}

/// The line after the block opened at [opened], which is where the indentation returns to it.
int _blockEnd(List<String> lines, int opened) {
  final int indent = _indent(lines[opened]);
  int end = opened + 1;
  while (end < lines.length && (lines[end].trim().isEmpty || _indent(lines[end]) > indent)) {
    end++;
  }
  return end;
}

int _indent(String line) => line.length - line.trimLeft().length;

String _unquote(String written) {
  if (written.length > 1 &&
      (written.startsWith('"') && written.endsWith('"') ||
          written.startsWith("'") && written.endsWith("'"))) {
    return written.substring(1, written.length - 1);
  }
  return written;
}
