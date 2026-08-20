/// external-secret-reach — every ExternalSecret this repository's applications read through the
/// Vault role `external-secrets` stands in a namespace that role admits, and names a Vault path some
/// `vault_kv_entry` row writes.
///
/// **WHAT AN EXTERNALSECRET NEEDS BEFORE ITS POLICY IS EVEN CONSULTED.** An ExternalSecret reaches
/// Vault through a SecretStore, and that store logs in with a ServiceAccount under a named
/// kubernetes-auth role. One family of roles here admits its callers by a LIST — the
/// `bound_service_account_namespaces` of the `external-secrets` role, which the deploy programs of
/// the installation repository write. A namespace absent from that list is refused at LOGIN, before
/// any policy is read, so nothing about the entry, the path or the policy matters: the seed reports
/// success, ArgoCD syncs, and every credential of that application is unreachable. The program
/// states that cost in its own words over the row, and names the ones it happened to — the registry,
/// postfix and the observability pair; `redis` was the next, and every one was found by hand.
///
/// **THE SAME DEFECT ONE STEP FURTHER IN** is a path. An admitted login with a granted policy still
/// reads nothing where no `vault_kv_entry` row ever wrote the entry, and it fails the same silent
/// way — the target Secret is never materialized, and the pod waits on a `secretKeyRef` naming a
/// Secret that will not appear. Both halves are held here, out of the same reading, because both are
/// one statement: what an ExternalSecret NAMES has to exist on the other side.
///
/// **THE SUBJECT IS ONE ROLE, AND THAT IS WHAT MAKES THE CHECK SOUND.** [listedRole] is the role
/// whose [namespaceListField] the deploy programs grow as applications are added, and it is that one
/// list this holds a reader to. Every other role this tree logs in under is admitted by its OWN row:
/// `consumer-eso`, `build-eso` and `tenant-eso-<stage>` select their callers by a LABEL SELECTOR,
/// and `manager-host` carries a [namespaceListField] of its own — one namespace, beside the one
/// `bound_service_account_names` entry it binds. What takes a reader of any of them out of the
/// subject is therefore not the SHAPE of its admission but that its role is not [listedRole], so the
/// list read here is not the row that governs it. So an ExternalSecret is
/// judged here only where the SecretStore it names, in its own namespace, authenticates under
/// [listedRole] — which is the store `charts/secret-store` renders with its own default role. The
/// path half takes the same subject, and that is deliberate: `apps/manager` reads
/// `<stage>/manager-host/ssh` through the separate `manager-host` role, and the program says in its
/// own words that nothing of that installation writes that entry and that nothing there can — an
/// absence that is stated, not overlooked, and not this role's business.
///
/// **WHICH LIST APPLIES IS DECIDED BY `runsOn`, NEVER BY THE UNION.** A master and a slave are two
/// Vault mounts with two lists in front of one KV tree: the master's rows stand in the program that
/// seeds a cluster, the slave's in the program that registers one, and the slave's list is the
/// smaller. Held against the union, a chart that only a slave runs passes on a namespace only the
/// master admits. So `app.yaml`'s `runsOn` picks the side — `every-cluster` is held to BOTH — and the
/// two sides are read apart by the MOUNT the row is written on: a mount naming [slavePlaceholder] is
/// a slave's own.
///
/// **A NAMESPACE IS ADMITTED ONLY WHERE EVERY ROW ON ITS SIDE ADMITS IT.** The master's role is
/// written by two rows guarded on mutually exclusive conditions — a build plane here, a build plane
/// elsewhere — and exactly one of them runs on a fresh installation. What is guaranteed is therefore
/// the INTERSECTION, and a namespace one row grew and the other did not is reported rather than
/// covered by its luckier twin.
///
/// **WHAT IT DOES NOT REACH.**
///
///   * ONLY `apps/`. What is read is the platform applications — a directory carrying an `app.yaml`,
///     which is what names a namespace and a `runsOn` at all. The ExternalSecrets of `slaves/`,
///     `units/`, `argocd/` and `bootstrap/` are read by nothing here, and the two halves are out of
///     reach there for different reasons — one of them a reason, the other only a gap.
///
///     The NAMESPACE half genuinely could not be held: `slaves/slave` and `slaves/dbgate` render
///     into a namespace named after the slave, admitted by a row that widens the master's role with
///     [slavePlaceholder] at registration time, and `units/` reads under `consumer-eso`, which
///     selects by label. Neither is a namespace this repository writes, so neither is a name this
///     check could hold to a list.
///
///     The PATH half is not like that, and for `slaves/dbgate` it is simply open. Its two
///     ExternalSecrets leave `vaultPath: ""` in `slaves/dbgate/values.yaml` (under
///     `externalsecret-db` and `externalsecret-redis`) and `argocd/apps/slaves-appset.yaml` stamps
///     `__STAGE__/app/mongodb` and `__STAGE__/app/redis` into them — two names as literal as the
///     `dev/app/redis` [vaultPathOf] already reduces, written in a spelling of the stage this
///     library does not read, and held to the written set by nothing. Misspell either entry and
///     this check stays green. `units/` is out of reach on this half for the stated reason instead:
///     `units/mongodb/values.yaml` and `units/postgresql/values.yaml` leave `vaultPath` empty and
///     the path is composed per consumer, when that consumer is onboarded.
///   * WHAT A ROW ADMITS AND NOTHING READS. The direction held is one way: every reader is admitted.
///     A namespace listed that no application of this tree reads through is reported by nothing —
///     the list carries names `preserve_list` keeps alive from earlier installations, and a check
///     demanding a reader for each would report those.
///   * A PATH NO SEGMENT OF WHICH IS LITERAL. A path a template composes out of a variable —
///     `{{ printf "build/%s/repo-pat" $unit }}` — names a different entry per unit, written when
///     that unit is onboarded rather than by any row of any program. It is passed over and counted,
///     never held to the written set, and the same goes for a namespace a template composes.
///   * THE PROPERTY, THE VALUE AND THE POLICY. That the path an ExternalSecret reads carries the
///     PROPERTY it asks for is not read here — `external-secret-keys` holds the key side of a
///     Secret, and no check of this package holds a `property` to the fields a `vault_kv_entry`
///     row writes. Neither is the policy: an admitted login can still be refused by a policy that
///     does not grant the path, and what the `token_policies` of the role permit is read by nothing
///     in this library.
///   * WHETHER THE CHART RENDERS AT ALL. A values block behind a condition that is false on every
///     installation is read here exactly as one that always renders, because `enabled` and a
///     chart-level `condition:` are values a render resolves and this reads the values as they stand
///     on disk.
library;

import 'dart:convert';

import 'external_secret_keys.dart' show commentFreeLines;

/// The Vault kubernetes-auth role whose admission is a namespace LIST rather than a label selector.
const String listedRole = 'external-secrets';

/// The field a `vault_auth_role` body writes that list into.
const String namespaceListField = 'bound_service_account_namespaces';

/// How the programs write the stage they are run for, wherever a stage stands in a path.
const String stagePlaceholder = '<stage>';

/// How the programs write the slave a run registers, wherever that slave's name stands.
const String slavePlaceholder = '<slave>';

/// The name `charts/secret-store` renders a SecretStore under unless an application overrides it.
const String defaultStoreName = 'vault-backend';

/// The chart an application embeds to get a SecretStore of [listedRole] in its own namespace.
const String secretStoreChart = 'charts/secret-store';

/// The chart an application embeds to get an ExternalSecret out of a values block.
const String externalSecretChart = 'charts/external-secret';

// ---------------------------------------------------------------------------------------------
// The programs' side: what a role admits, and what a row writes.
// ---------------------------------------------------------------------------------------------

/// One `vault_auth_role` row's namespace list, as one program writes it.
final class AdmittedNamespaces {
  /// Records that [program] writes [role] on [mount] admitting [namespaces].
  const AdmittedNamespaces({
    required this.program,
    required this.mount,
    required this.role,
    required this.namespaces,
  });

  /// The program, as a path that names the file somebody has to open.
  final String program;

  /// The kubernetes auth mount the role stands on — a master's or a slave's own.
  final String mount;

  /// The role the row writes.
  final String role;

  /// The namespaces it admits, exactly as written, placeholders included.
  final List<String> namespaces;

  /// Whether the mount this row stands on is a slave's own.
  ///
  /// A slave's mount is named after the slave, so the program writes [slavePlaceholder] into it;
  /// the master's mount carries no slave's name because there is one master per installation.
  bool get onASlavesOwnMount => mount.contains(slavePlaceholder);

  /// The namespaces it admits that name a namespace this repository could write.
  Set<String> get literalNamespaces => <String>{
    for (final String each in namespaces)
      if (!each.contains('<')) each,
  };

  /// The one line a finding says about the row.
  @override
  String toString() => '$program role "$role" on mount "$mount"';
}

/// Every `vault_auth_role` row of [document] that admits by a namespace list, where [document] is
/// the parsed YAML of the program standing at [program].
///
/// The walk is over the whole document rather than over a known step shape, for the reason
/// `vault_selector_labels.dart` gives about the twin field: the list is written inside a step's
/// `body`, a string of JSON handed to Vault, and which steps carry such a body is the program's
/// business. Any string value naming [namespaceListField] is decoded, and the map it sits in is
/// taken for the step, so that step's `role` and `mount` name the row in a finding.
///
/// A string that is EXACTLY the field name is the one exception, and it is not a pass-over: that is
/// `preserve_list: bound_service_account_namespaces` and the `list:` of a removal, which NAME the
/// field rather than writing a list into it. Decoding one as a body would refuse over every program
/// that carries the very argument making a role write a widening instead of a replacement.
///
/// Throws a [FormatException] naming [program] where a string names the field and the list cannot be
/// decoded: a row held to nothing is a pass this check may not give.
List<AdmittedNamespaces> admittedNamespacesIn({
  required String program,
  required Object? document,
}) {
  final List<AdmittedNamespaces> found = <AdmittedNamespaces>[];
  void walk(Object? node) {
    if (node is Map) {
      for (final Object? value in node.values) {
        if (value is String && value.trim() == namespaceListField) {
          continue;
        }
        if (value is String && value.contains(namespaceListField)) {
          found.add(
            AdmittedNamespaces(
              program: program,
              mount: node['mount'] is String ? node['mount']! as String : '?',
              role: node['role'] is String ? node['role']! as String : '?',
              namespaces: _namespaceListOf(program, value),
            ),
          );
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

/// The namespaces the body in [body] admits, or the refusal that [program] wrote one this cannot
/// read.
List<String> _namespaceListOf(String program, String body) {
  Never unreadable(String detail) => throw FormatException(
    '$program writes $namespaceListField but $detail — what cannot be read cannot be held to the '
    'namespaces this repository renders into, so this is an error and never a pass',
  );

  final Object? step;
  try {
    step = jsonDecode(body);
  } on FormatException catch (each) {
    unreadable('the body around it is not JSON (${each.message})');
  }
  if (step is! Map) {
    unreadable('the body around it decodes to ${step.runtimeType} rather than to an object');
  }
  final Object? listed = step[namespaceListField];
  if (listed is! List) {
    unreadable('$namespaceListField holds ${listed.runtimeType} rather than a list');
  }
  return <String>[
    for (final Object? each in listed)
      if (each is String) each else unreadable('one entry of the list is not a string'),
  ];
}

/// What the rows of a whole installation guarantee an ExternalSecret of [listedRole].
final class Admission {
  /// Records that a master admits [onMaster], a slave admits [onSlave], and [passedOver] rows
  /// decided neither.
  const Admission({required this.onMaster, required this.onSlave, required this.passedOver});

  /// The namespaces EVERY row on a master's mount admits.
  final Set<String> onMaster;

  /// The namespaces EVERY row on a slave's own mount admits.
  final Set<String> onSlave;

  /// The rows that named no namespace this repository writes, and are held to nothing.
  final List<String> passedOver;
}

/// What [rows] guarantee, per side, for [listedRole].
///
/// The INTERSECTION per side rather than the union, because the rows of one side are alternatives:
/// the master's two are guarded on mutually exclusive conditions and exactly one runs on a fresh
/// installation, so what is guaranteed is what both admit. A row whose every entry is a placeholder
/// — the widening a registration writes for the slave's own name — decides nothing about a namespace
/// this repository can name, and taking it into an intersection would empty the side.
Admission admissionOf(Iterable<AdmittedNamespaces> rows) {
  final List<String> passedOver = <String>[];
  Set<String>? master;
  Set<String>? slave;

  for (final AdmittedNamespaces row in rows) {
    if (row.role != listedRole) {
      continue;
    }
    final Set<String> literal = row.literalNamespaces;
    if (literal.isEmpty) {
      passedOver.add(
        '$row admits ${row.namespaces.join(', ')} — every entry names a cluster rather than a '
        'namespace this repository writes, so the row is held to nothing',
      );
      continue;
    }
    if (row.onASlavesOwnMount) {
      slave = slave == null ? literal : slave.intersection(literal);
    } else {
      master = master == null ? literal : master.intersection(literal);
    }
  }

  return Admission(
    onMaster: master ?? const <String>{},
    onSlave: slave ?? const <String>{},
    passedOver: passedOver,
  );
}

/// Every Vault path the `vault_kv_entry` rows of [document] write.
///
/// A `copy_from` is a SOURCE, not a second destination: the row at
/// `deploy-gitops.yaml` that copies the identity provider's minted client secret into the
/// application tier writes the entry its own `path` names, and reads the one `copy_from` names. So
/// what is collected is the `path` of each row, which is the entry that exists afterwards.
Set<String> writtenVaultPathsIn({required Object? document}) {
  final Set<String> found = <String>{};
  void walk(Object? node) {
    if (node is Map) {
      if (node['step'] == 'vault_kv_entry' && node['path'] is String) {
        found.add(node['path']! as String);
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
  return found;
}

// ---------------------------------------------------------------------------------------------
// This tree's side: the stores an application renders, and the ExternalSecrets that read through
// them.
// ---------------------------------------------------------------------------------------------

/// One SecretStore an application renders, and the Vault role it logs in under.
final class RenderedStore {
  /// Records that [where] renders a store [name] in [namespace] logging in under [role].
  const RenderedStore({
    required this.where,
    required this.namespace,
    required this.name,
    required this.role,
  });

  /// The file somebody has to open, as a path relative to the repository.
  final String where;

  /// The namespace the store stands in.
  final String namespace;

  /// The store's name, which is what an ExternalSecret references it by.
  final String name;

  /// The Vault kubernetes-auth role it logs in under.
  final String role;
}

/// One ExternalSecret an application renders.
final class SecretReader {
  /// Records that [where] renders a reader in [namespace] through the store [storeName], reading
  /// [vaultPaths] and passing over [unreadablePaths].
  const SecretReader({
    required this.where,
    required this.application,
    required this.namespace,
    required this.storeName,
    required this.vaultPaths,
    required this.unreadablePaths,
  });

  /// The file somebody has to open, as a path relative to the repository.
  final String where;

  /// The application directory it belongs to, such as `apps/redis`.
  final String application;

  /// The namespace it stands in, or null where a template composes it.
  final String? namespace;

  /// The store it reads through, or null where a template composes the name.
  final String? storeName;

  /// The Vault paths it reads, as the programs write a path.
  final Set<String> vaultPaths;

  /// The paths it reads that no reading here reduces to literals, exactly as written.
  final Set<String> unreadablePaths;
}

/// What one application's files say about its stores and its readers.
final class ApplicationReading {
  /// Records that an application renders [stores] and [readers].
  const ApplicationReading({required this.stores, required this.readers});

  /// The SecretStores it renders.
  final List<RenderedStore> stores;

  /// The ExternalSecrets it renders.
  final List<SecretReader> readers;
}

/// One application's placement, out of its `app.yaml`.
final class ApplicationPlacement {
  /// Records that the application at [application] runs in [namespace] on [runsOn].
  const ApplicationPlacement({
    required this.application,
    required this.namespace,
    required this.runsOn,
  });

  /// The application directory, such as `apps/redis`.
  final String application;

  /// The namespace its release stands in, which is where an ExternalSecret naming none lands.
  final String namespace;

  /// Which cluster it runs on — `master`, `slave` or `every-cluster`.
  final String runsOn;

  /// Whether a master's list has to admit its namespace.
  bool get onAMaster => runsOn == 'master' || runsOn == 'every-cluster';

  /// Whether a slave's list has to admit its namespace.
  bool get onASlave => runsOn == 'slave' || runsOn == 'every-cluster';
}

/// The placement [source] states, where [source] is the `app.yaml` of [application].
///
/// Read line by line rather than through a YAML parse for the reason every reader in this library
/// is: what is read out of an application is read out of files Helm templates, and one reader over
/// all of them is one shape to hold right.
ApplicationPlacement? placementIn({required String application, required String source}) {
  String? namespace;
  String? runsOn;
  for (final String line in commentFreeLines(source)) {
    if (_scalar(line, 'namespace') case final String found when namespace == null) {
      namespace = found;
    }
    if (_scalar(line, 'runsOn') case final String found when runsOn == null) {
      runsOn = found;
    }
  }
  if (namespace == null || runsOn == null) {
    return null;
  }
  return ApplicationPlacement(application: application, namespace: namespace, runsOn: runsOn);
}

/// The names an application's values blocks for [chart] hang under, out of its `Chart.yaml`.
///
/// A dependency is addressed in values by its `alias` where it carries one and by its `name`
/// otherwise, and both chart-store and chart-secret are embedded several times over under different
/// aliases — `apps/observability` carries three of `charts/external-secret`. Reading the aliases is
/// what keeps an `externalSecret:` block that is NOT that chart's from being read as one.
Set<String> valuesKeysFor({required String source, required String chart}) {
  final Set<String> keys = <String>{};
  String? name;
  String? alias;
  String? repository;
  void close() {
    if (name != null && repository != null && repository.endsWith(chart)) {
      keys.add(alias ?? name);
    }
  }

  for (final String line in commentFreeLines(source)) {
    if (_entry(line, 'name') case final String found) {
      close();
      name = found;
      alias = null;
      repository = null;
      continue;
    }
    if (_scalar(line, 'alias') case final String found) {
      alias = found;
    }
    if (_scalar(line, 'repository') case final String found) {
      repository = found;
    }
  }
  close();
  return keys;
}

/// What the files of the application at [application] say, where [files] holds the source of each by
/// its path relative to the repository.
///
/// [files] carries the application's `Chart.yaml`, its values files and its templates. The values
/// blocks of ONE dependency are merged across the files that layer onto it: an application states an
/// ExternalSecret's name and namespace in `values-common.yaml` and its Vault path in
/// `values-<stage>.yaml`, so a reader built per file would report every one of them as a reader with
/// no path and hold none of them to anything.
ApplicationReading readApplication({
  required String application,
  required ApplicationPlacement placement,
  required Map<String, String> files,
}) {
  final String chart = files['$application/Chart.yaml'] ?? '';
  final Set<String> storeKeys = valuesKeysFor(source: chart, chart: secretStoreChart);
  final Set<String> secretKeys = valuesKeysFor(source: chart, chart: externalSecretChart);

  final List<RenderedStore> stores = <RenderedStore>[
    for (final String _ in storeKeys)
      RenderedStore(
        where: '$application/Chart.yaml',
        namespace: placement.namespace,
        name: defaultStoreName,
        role: listedRole,
      ),
  ];
  final Map<String, _MergedBlock> merged = <String, _MergedBlock>{};
  final List<SecretReader> readers = <SecretReader>[];

  for (final String path in files.keys.toList()..sort()) {
    final List<String> lines = commentFreeLines(files[path]!);
    final String? stage = _stageOf(path);
    stores.addAll(_storesIn(where: path, lines: lines, placement: placement));
    readers.addAll(
      _templateReadersIn(where: path, lines: lines, placement: placement, stage: stage),
    );
    _mergeValuesBlocks(
      into: merged,
      where: path,
      lines: lines,
      stage: stage,
      storeKeys: storeKeys,
      secretKeys: secretKeys,
      stores: stores,
    );
  }

  for (final String key in merged.keys.toList()..sort()) {
    final _MergedBlock block = merged[key]!;
    readers.add(
      SecretReader(
        where: block.where,
        application: application,
        namespace: block.namespace ?? placement.namespace,
        storeName: block.storeName ?? defaultStoreName,
        vaultPaths: block.vaultPaths,
        unreadablePaths: block.unreadablePaths,
      ),
    );
  }

  return ApplicationReading(stores: stores, readers: readers);
}

/// One dependency's values block, as the files that layer onto it leave it.
///
/// [declaredIn] is where the block first stands and [pathsIn] is every file that writes a
/// `vaultPath` into it — three of them, one per stage, wherever a stage decides the entry. A finding
/// names all three rather than whichever the sort happened to end on, because all three carry the
/// path and all three are what somebody has to open.
final class _MergedBlock {
  _MergedBlock(this.declaredIn);

  final String declaredIn;
  final Set<String> pathsIn = <String>{};
  String? namespace;
  String? storeName;
  final Set<String> vaultPaths = <String>{};
  final Set<String> unreadablePaths = <String>{};

  String get where => pathsIn.isEmpty ? declaredIn : (pathsIn.toList()..sort()).join(', ');
}

/// Every SecretStore the document of [lines] renders as a `kind: SecretStore` template.
List<RenderedStore> _storesIn({
  required String where,
  required List<String> lines,
  required ApplicationPlacement placement,
}) {
  final List<RenderedStore> found = <RenderedStore>[];
  for (final List<String> document in _documentsIn(lines)) {
    if (!document.any((String line) => _kindIs(line, 'SecretStore'))) {
      continue;
    }
    final String? name = _metadataOf(document, 'name');
    final String? namespace = _namespaceOf(document, placement);
    final String? role = _firstScalar(document, 'role');
    if (name == null || namespace == null || role == null) {
      continue;
    }
    found.add(RenderedStore(where: where, namespace: namespace, name: name, role: role));
  }
  return found;
}

/// Every ExternalSecret the documents of [lines] render as a `kind: ExternalSecret` template.
List<SecretReader> _templateReadersIn({
  required String where,
  required List<String> lines,
  required ApplicationPlacement placement,
  required String? stage,
}) {
  final List<SecretReader> found = <SecretReader>[];
  for (final List<String> document in _documentsIn(lines)) {
    if (!document.any((String line) => _kindIs(line, 'ExternalSecret'))) {
      continue;
    }
    final Set<String> paths = <String>{};
    final Set<String> unreadable = <String>{};
    for (final String line in document) {
      if (_scalar(line, 'key', templated: true) case final String written) {
        final String? path = vaultPathOf(written, stage: stage);
        (path == null ? unreadable : paths).add(path ?? written);
      }
    }
    found.add(
      SecretReader(
        where: where,
        application: placement.application,
        namespace: _namespaceOf(document, placement),
        storeName: _storeReferenceIn(document),
        vaultPaths: paths,
        unreadablePaths: unreadable,
      ),
    );
  }
  return found;
}

/// Merges every `externalSecret:` block of [lines] into [into], and takes a `role` or a `name` a
/// `secret-store` block overrides into [stores].
void _mergeValuesBlocks({
  required Map<String, _MergedBlock> into,
  required String where,
  required List<String> lines,
  required String? stage,
  required Set<String> storeKeys,
  required Set<String> secretKeys,
  required List<RenderedStore> stores,
}) {
  for (int i = 0; i < lines.length; i++) {
    final String? key = _blockKey(lines[i]);
    if (key == null) {
      continue;
    }
    final List<String> block = lines.sublist(i + 1, _blockEnd(lines, i));
    if (storeKeys.contains(key)) {
      final String? role = _firstScalar(block, 'role');
      final String? name = _firstScalar(block, 'name');
      for (int each = 0; each < stores.length; each++) {
        if (stores[each].name != defaultStoreName || stores[each].role != listedRole) {
          continue;
        }
        stores[each] = RenderedStore(
          where: where,
          namespace: stores[each].namespace,
          name: name ?? stores[each].name,
          role: role ?? stores[each].role,
        );
      }
      continue;
    }
    if (!secretKeys.contains(key)) {
      continue;
    }
    final _MergedBlock merged = into.putIfAbsent(key, () => _MergedBlock(where));
    for (final String line in block) {
      if (_scalar(line, 'namespace') case final String found) {
        merged.namespace = found;
      }
      if (_scalar(line, 'secretStoreName') case final String found) {
        merged.storeName = found;
      }
      if (_scalar(line, 'vaultPath') case final String written) {
        merged.pathsIn.add(where);
        final String? path = vaultPathOf(written, stage: stage);
        (path == null ? merged.unreadablePaths : merged.vaultPaths).add(path ?? written);
      }
    }
  }
}

// ---------------------------------------------------------------------------------------------
// Holding one side to the other.
// ---------------------------------------------------------------------------------------------

/// One way an ExternalSecret of [listedRole] reaches nothing.
sealed class ReachFinding {
  const ReachFinding();
}

/// A reader standing in a namespace the role does not admit.
final class UnadmittedNamespace extends ReachFinding {
  /// Records that [reader] stands in a namespace no row of [side] admits.
  const UnadmittedNamespace({required this.reader, required this.side, required this.admitted});

  /// The reader that is refused.
  final SecretReader reader;

  /// Which list was consulted — `a master` or `a slave`.
  final String side;

  /// What that list admits, so a finding says what to add the namespace to.
  final Set<String> admitted;

  /// The one line a refusal says about it.
  @override
  String toString() =>
      '${reader.where} renders an ExternalSecret in namespace "${reader.namespace}", which no '
      '$namespaceListField row of $side admits for role "$listedRole" — the login is refused '
      'before any policy is consulted, so every credential of ${reader.application} is unreachable '
      'while the seed reports success. $side admits ${(admitted.toList()..sort()).join(', ')}';
}

/// A reader whose store no application of this tree renders into its namespace.
final class UnresolvableStore extends ReachFinding {
  /// Records that nothing renders the store [reader] names where [reader] stands.
  const UnresolvableStore({required this.reader});

  /// The reader whose login cannot be traced to a role.
  final SecretReader reader;

  /// The one line a refusal says about it.
  @override
  String toString() =>
      '${reader.where} renders an ExternalSecret in namespace "${reader.namespace}" reading '
      'through a store "${reader.storeName}", and no application under apps/ renders a SecretStore '
      'of that name into that namespace — which role it logs in under is therefore unknown, and '
      'whether any $namespaceListField row admits the namespace cannot be decided. Either the '
      'namespace is one nothing sets a store up in, or the store is rendered somewhere this check '
      'does not read and this reader belongs outside it';
}

/// A reader naming a Vault path no row writes.
final class UnwrittenVaultPath extends ReachFinding {
  /// Records that [reader] reads [path] and no `vault_kv_entry` row writes it.
  const UnwrittenVaultPath({required this.reader, required this.path});

  /// The reader that reads nothing.
  final SecretReader reader;

  /// The path it names, as the programs write a path.
  final String path;

  /// The one line a refusal says about it.
  @override
  String toString() =>
      '${reader.where} renders an ExternalSecret reading "$path", and no vault_kv_entry row of any '
      'program writes that entry — the login is admitted, the policy grants the tier and the read '
      'returns nothing, so the target Secret is never materialized and the pod of '
      '${reader.application} waits on a Secret that will not appear';
}

/// What holding this tree's readers to an installation found, and what it could not hold.
final class ReachAudit {
  /// Records [findings] over [judged] readers, with [passedOver] saying why the rest were not held.
  const ReachAudit({required this.judged, required this.passedOver, required this.findings});

  /// The readers held to both sides.
  final List<SecretReader> judged;

  /// Every reader not held, and the reason, in the words whoever wrote it reads.
  final List<String> passedOver;

  /// Every way a reader reaches nothing.
  final List<ReachFinding> findings;
}

/// Holds every reader of [readers] to [admission] and to [written].
///
/// [stores] is every SecretStore this tree renders, and it is what decides the SUBJECT: a reader is
/// judged only where the store it names, in its own namespace, logs in under [listedRole]. A reader
/// whose store or namespace a TEMPLATE composes is passed over by name — what it reaches cannot be
/// read from a values file, and reporting it would be reporting this library's own reach.
///
/// A reader whose namespace and store are both literal and whose store nothing renders there is
/// REPORTED rather than passed over, and the difference matters: a namespace no application sets a
/// store up in is a namespace no row admits either, so passing it over would let the defect this
/// check exists for through whenever the ExternalSecret carries a `namespace:` of its own.
ReachAudit auditExternalSecretReach({
  required List<SecretReader> readers,
  required List<RenderedStore> stores,
  required Map<String, ApplicationPlacement> placements,
  required Admission admission,
  required Set<String> written,
}) {
  final Map<String, RenderedStore> byNamespace = <String, RenderedStore>{
    for (final RenderedStore each in stores) '${each.namespace}/${each.name}': each,
  };
  final List<SecretReader> judged = <SecretReader>[];
  final List<String> passedOver = <String>[];
  final List<ReachFinding> found = <ReachFinding>[];

  for (final SecretReader reader in readers) {
    if (reader.namespace == null || reader.storeName == null) {
      passedOver.add(
        '${reader.where} renders an ExternalSecret whose '
        '${reader.namespace == null ? 'namespace' : 'store'} a template composes — which role it '
        'logs in under is not readable from the file',
      );
      continue;
    }
    final RenderedStore? store = byNamespace['${reader.namespace}/${reader.storeName}'];
    if (store == null) {
      found.add(UnresolvableStore(reader: reader));
      continue;
    }
    if (store.role != listedRole) {
      passedOver.add(
        '${reader.where} reads through "${store.name}", which logs in under role "${store.role}" '
        '(${store.where}) rather than under "$listedRole" — what admits it is that role\'s own row, '
        'not the $namespaceListField this holds a reader to',
      );
      continue;
    }

    judged.add(reader);
    final ApplicationPlacement placement = placements[reader.application]!;
    if (placement.onAMaster && !admission.onMaster.contains(reader.namespace)) {
      found.add(
        UnadmittedNamespace(reader: reader, side: 'a master', admitted: admission.onMaster),
      );
    }
    if (placement.onASlave && !admission.onSlave.contains(reader.namespace)) {
      found.add(UnadmittedNamespace(reader: reader, side: 'a slave', admitted: admission.onSlave));
    }
    for (final String path in reader.vaultPaths.toList()..sort()) {
      if (!written.contains(path)) {
        found.add(UnwrittenVaultPath(reader: reader, path: path));
      }
    }
    for (final String path in reader.unreadablePaths.toList()..sort()) {
      passedOver.add(
        '${reader.where} reads "$path", whose segments a template composes — the entry it names '
        'differs per unit and is written when that unit is onboarded, not by a row of a program',
      );
    }
  }

  return ReachAudit(judged: judged, passedOver: passedOver, findings: found);
}

// ---------------------------------------------------------------------------------------------
// Reading a path, a namespace and a document out of lines Helm templates.
// ---------------------------------------------------------------------------------------------

final RegExp _printf = RegExp(r'^\{\{-?\s*printf\s+"([^"]*)"\s+(.*?)\s*-?\}\}$');

/// What [written] names, as the programs write a path, or null where it is not all literal.
///
/// Three shapes reach here and each is a different half of the same sentence. A template writes
/// `{{ printf "%s/app/registry" .Values.global.env }}`, and the one argument this resolves is the
/// stage — every other argument names a unit or a variable whose value differs per render, and a
/// path built out of one is not an entry any program writes. A per-stage values file writes the
/// stage as a LITERAL — `dev/app/redis` — and [stage] is that file's own stage, taken from its name
/// rather than from a list of stages this library would then be a second copy of. A path with no
/// stage in it at all — `build/catalog/repo-pat` — passes through as written, which is how the
/// programs write it too.
String? vaultPathOf(String written, {required String? stage}) {
  String bare = _unquote(written.trim());
  if (_printf.firstMatch(bare) case final RegExpMatch found) {
    final List<String> arguments = found.group(2)!.split(RegExp(r'\s+'));
    String format = found.group(1)!;
    for (final String argument in arguments) {
      if (argument != '.Values.global.env' || !format.contains('%s')) {
        return null;
      }
      format = format.replaceFirst('%s', stagePlaceholder);
    }
    bare = format;
  }
  if (bare.isEmpty || bare.contains('{{') || bare.contains('%')) {
    return null;
  }
  if (stage == null) {
    return bare;
  }
  return bare.split('/').map((String each) => each == stage ? stagePlaceholder : each).join('/');
}

/// The stage the file at [path] is the per-stage layer of, or null where it is not one.
///
/// Taken from the file's own name rather than from a list of the stages this installation has: a
/// list would be a second truth, and the day a stage is added the check would go on reading the old
/// three and quietly stop normalising the new one's paths.
String? _stageOf(String path) {
  final RegExpMatch? found = RegExp(r'/values-([a-z0-9]+)\.yaml$').firstMatch(path);
  if (found == null || found.group(1) == 'common') {
    return null;
  }
  return found.group(1);
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

/// Whether [line] is a document's own `kind:` naming [kind].
///
/// At column zero, which is what tells a document's kind from a `kind:` nested inside one — the
/// vendored `CustomResourceDefinition` in `apps/external-secrets/templates/` names `ExternalSecret`
/// under `spec.names.kind`, and reading that as an ExternalSecret would hold a CRD to a namespace
/// list.
bool _kindIs(String line, String kind) => RegExp('^kind:\\s*$kind\\s*\$').hasMatch(line);

/// The namespace [document] stands in — its own `metadata.namespace` where it names one, and the
/// release's otherwise — or null where a template composes it.
String? _namespaceOf(List<String> document, ApplicationPlacement placement) {
  final String? written = _metadataOf(document, 'namespace');
  if (written == null) {
    return _metadataOf(document, 'name') == null ? null : placement.namespace;
  }
  if (written == '{{ .Release.Namespace }}') {
    return placement.namespace;
  }
  return written.contains('{{') ? null : written;
}

/// The `metadata.<field>` of [document], or null where the block names none or a template composes
/// it.
String? _metadataOf(List<String> document, String field) {
  for (int i = 0; i < document.length; i++) {
    if (!RegExp(r'^metadata:\s*$').hasMatch(document[i])) {
      continue;
    }
    for (final String line in document.sublist(i + 1, _blockEnd(document, i))) {
      if (_scalar(line, field, templated: true) case final String found) {
        return found;
      }
    }
  }
  return null;
}

/// The store `spec.secretStoreRef.name` of [document] names, or null where a template composes it.
///
/// `{{ .Values.global.secretStoreName }}` resolves to [defaultStoreName]: it is the ONE platform
/// global that names a store, written once in `platform/values-common.yaml`, and an ExternalSecret
/// naming it means the store its own application renders rather than a store of its own.
String? _storeReferenceIn(List<String> document) {
  for (int i = 0; i < document.length; i++) {
    if (!RegExp(r'^\s*secretStoreRef:\s*$').hasMatch(document[i])) {
      continue;
    }
    for (final String line in document.sublist(i + 1, _blockEnd(document, i))) {
      if (_scalar(line, 'name', templated: true) case final String found) {
        if (found == '{{ .Values.global.secretStoreName }}') {
          return defaultStoreName;
        }
        return found.contains('{{') ? null : found;
      }
    }
  }
  return null;
}

/// The key of the block [line] opens, or null where it opens none.
String? _blockKey(String line) =>
    RegExp(r'^(\s*)([A-Za-z][A-Za-z0-9_.-]*):\s*$').firstMatch(line)?.group(2);

/// The value [line] writes for [field], or null where it writes something else.
///
/// A value a template composes is null unless [templated] says the caller resolves one itself: a
/// path or a name half-read is worse than one not read, because it is held to the other side as if
/// it were what the render produces.
String? _scalar(String line, String field, {bool templated = false}) {
  final RegExpMatch? found = RegExp('^\\s*(?:-\\s+)?$field:\\s*(\\S.*?)\\s*\$').firstMatch(line);
  if (found == null) {
    return null;
  }
  final String bare = _unquote(found.group(1)!);
  if (bare.isEmpty) {
    return null;
  }
  return templated || !bare.contains('{{') ? bare : null;
}

/// The value [line] writes for a list entry opening with [field], or null where it opens none.
String? _entry(String line, String field) =>
    RegExp('^\\s*-\\s+$field:\\s*(\\S.*?)\\s*\$').firstMatch(line)?.group(1);

/// The first [field] any line of [lines] writes.
String? _firstScalar(List<String> lines, String field) {
  for (final String line in lines) {
    if (_scalar(line, field) case final String found) {
      return found;
    }
  }
  return null;
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
