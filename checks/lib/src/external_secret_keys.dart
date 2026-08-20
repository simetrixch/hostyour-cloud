/// external-secret-keys — where a Secret of this tree is read key by key and no other way, every
/// key its ExternalSecret declares is a key some workload here names, and every key a workload
/// names is a key that ExternalSecret declares.
///
/// **What the subject is.** An ExternalSecret says which properties of a Vault path become which
/// keys of a Kubernetes Secret: one `- secretKey: <name>` entry per key, under `spec.data` in a
/// template such as `apps/manager/templates/externalsecret-app.yaml`, or under
/// `externalSecret.data` in a values file that `charts/external-secret` renders, such as
/// `slaves/dbgate/values.yaml`. A workload then reaches into that Secret. Nothing connects the two
/// halves: ESO writes every key it was told to write whether or not anything reads it, and a
/// container that names a key nobody wrote never starts.
///
/// **Both halves fail silently, in opposite directions.** A key nothing reads is a credential at
/// rest that no rotation covers and no inventory counts — hostyour-cloud#62 is one, the sudo
/// password written into `secret/<stage>/app/manager` and projected into `manager-app` while the
/// only reader of that Secret took `oidc-client-secret` out of it. A key nothing declares is the
/// mirror: the Deployment is correct, the Secret is correct, and the pod sits in
/// `CreateContainerConfigError` until somebody reads the event.
///
/// **WHICH SECRETS ARE JUDGED, AND WHY IT IS THE NARROW SET.** A Secret's keys are only legible
/// where the tree reads them one at a time. Most Secrets here travel whole — through
/// `envFrom: - secretRef:`, through a volume that mounts the Secret without `items:`, through an
/// upstream chart's own `existingSecret:` value, or through a config string such as the
/// `remote.kubernetes.secret` block in `charts/monitoring/templates/alloy-agent-config.yaml`. What a
/// whole-travelling Secret's consumer does with each key is not stated anywhere this repository can
/// read, so those keys are not judged — NOT because they are known to be consumed, but because
/// nothing here can tell. The tree declares 50 keys across the 32 Secrets it names, 14 of them are
/// named by a `secretKeyRef`, and a check demanding one per declared key would report the other 36
/// without having read anything about them. Those three numbers are asserted by the suite
/// beside this file, so they cannot go stale here without the gate saying so. A Secret is held to
/// the whole rule only where all of this is true, and every Secret that fails one of them is named
/// with the reason instead of counted:
///
///   * an ExternalSecret of this tree declares it, and its `target` carries no `template:` — with a
///     template the `secretKey` entries are the template's inputs and the Secret's keys are the
///     template's own, so `apps/manager/templates/externalsecret-registry.yaml` declares `user` and
///     `pass` and writes `.dockerconfigjson`;
///   * every `secretKey` it declares is written out, not composed by a template expression;
///   * at least one `secretKeyRef` of this tree names it, which is what makes its key set legible
///     here at all;
///   * its name appears nowhere else in the tree once comments are removed — not in a volume, not
///     in an `envFrom`, not as a value of another chart. This is the load-bearing half: it does not
///     enumerate the ways a Secret can be taken whole, it requires that the name is not written
///     anywhere this check has not already accounted for, so a consumption shape nobody has thought
///     of yet takes its Secret out of the judged set rather than turning into a false refusal.
///
/// The mirror finding is wider than that, because a `creationPolicy: Owner` ExternalSecret with no
/// template owns the whole key set of its Secret: a `secretKeyRef` naming a key such a declaration
/// does not carry is wrong however the rest of that Secret is consumed.
///
/// **WHAT IT DOES NOT REACH, named one by one rather than counted.**
///
///   * **A reader outside this repository.** The tree it reads is this repository. The manager's own
///     source lives in `hostyour-manager` and the deploy programs that write these Vault paths live
///     in `digita-deploy`, so a key either of them reads is a key this check would call unread. That
///     is what keeps the judged set narrow enough to be read: the Secrets in it are the ones whose
///     readers are workloads declared here.
///   * **Namespaces.** A Secret is a name, not a name in a namespace. `mongodb-credentials` is
///     declared by `apps/mongodb/values-common.yaml` and again by `units/mongodb/values.yaml`, and
///     both declarations and every reference to that name are one Secret here: the declarations are
///     folded into one before anything is judged, so two same-named Secrets whose key sets differ
///     are held to the union of them and a key that only one of them carries is not reported.
///   * **What Vault holds.** Whether the `property` a `secretKey` reads exists in the path named
///     beside it is not readable from this tree, and a key that resolves to nothing at sync time is
///     as green here as one that resolves.
///   * **`enabled: false`.** A values-declared ExternalSecret is read whether or not its chart
///     renders it, so a key declared under a switch that is off everywhere is judged like any other.
///   * **Rendered output.** It reads the tracked YAML as text, the way `published_databases.dart`
///     does, not what Helm produces. A target Secret name written as a template expression —
///     `charts/external-secret/templates/externalsecret.yaml` is the generic renderer and names its
///     target through `.Values` — cannot be resolved, and its declaration is passed over by the path
///     it stands at rather than by a Secret name. A values block that declares keys and no
///     `targetSecretName` is passed over the same way: the chart defaults that target to
///     `common.fullname`, so reading the block's own `name` would state a Secret it does not write.
///   * **A name that occurs only inside another ExternalSecret.** The declaring document is removed
///     whole before the rest of the tree is scanned for the name, so a Secret named nowhere but
///     inside some other ExternalSecret document would still be judged.
library;

/// A Kubernetes Secret an ExternalSecret of this tree materializes.
final class DeclaredSecret {
  /// Records that the file at [where] declares [secret] with [keys].
  const DeclaredSecret({
    required this.secret,
    required this.keys,
    required this.templated,
    required this.unreadableKeys,
    required this.where,
  });

  /// The target Secret's name, or null where the declaration composes it with a template
  /// expression this tree cannot resolve.
  final String? secret;

  /// The keys it declares, as the `- secretKey:` entries write them.
  final Set<String> keys;

  /// Whether its `target` carries a `template:`, which makes the Secret's keys the template's own
  /// rather than these.
  final bool templated;

  /// How many `- secretKey:` entries are written as a template expression rather than a name.
  final int unreadableKeys;

  /// The file somebody opens to change it, as a path relative to the repository root.
  final String where;
}

/// A key of a Secret one workload of this tree names through a `secretKeyRef`.
final class SecretKeyReference {
  /// Records that the file at [where] reads [key] out of [secret].
  const SecretKeyReference({required this.secret, required this.key, required this.where});

  /// The Secret the reference names.
  final String secret;

  /// The key it takes out of it.
  final String key;

  /// The file somebody opens to change it, as a path relative to the repository root.
  final String where;
}

/// Something wrong between what an ExternalSecret declares and what this tree reads.
sealed class KeyFinding {
  /// The Secret the finding is about.
  String get secret;

  /// The key it is about.
  String get key;
}

/// A declared key no workload of this tree names.
final class UnreadKey implements KeyFinding {
  /// Records that [secret], declared at [where], carries [key] and nothing here reads it.
  const UnreadKey({required this.secret, required this.key, required this.where});

  @override
  final String secret;

  @override
  final String key;

  /// The file the declaration stands in.
  final String where;

  @override
  String toString() =>
      '$where declares key "$key" of Secret "$secret", and no secretKeyRef of this tree names it — '
      'the whole of that Secret is read key by key here, so the key is written into the cluster on '
      'every sync, read by nothing, rotated by nothing, and counted by nobody as a credential in '
      'use';
}

/// A key a workload names that its ExternalSecret does not declare.
final class UndeclaredKey implements KeyFinding {
  /// Records that [where] reads [key] out of [secret], which is declared at [declaredAt] without
  /// it.
  const UndeclaredKey({
    required this.secret,
    required this.key,
    required this.where,
    required this.declaredAt,
  });

  @override
  final String secret;

  @override
  final String key;

  /// The file the reference stands in.
  final String where;

  /// The file the declaration stands in.
  final String declaredAt;

  @override
  String toString() =>
      '$where reads key "$key" out of Secret "$secret", and $declaredAt declares that Secret '
      'without it — ESO writes the keys it was told to write, so the Secret arrives complete, the '
      'workload references a key that is not in it, and the pod stays in '
      'CreateContainerConfigError';
}

/// What one run of this check covered and what it found.
final class KeyAudit {
  /// Records that [judged] were held to the whole rule, [passedOver] were not and why, and
  /// [findings] is what the run found.
  const KeyAudit({required this.judged, required this.passedOver, required this.findings});

  /// The Secrets every declared key of which had to be named by a `secretKeyRef`.
  final Set<String> judged;

  /// Every declared Secret that was not, by the words a reader decides on: its name, or the file it
  /// stands in where the name could not be read.
  final Map<String, String> passedOver;

  /// Everything wrong with the ones that were judged, plus every undeclared key of any declaration
  /// with no template.
  final List<KeyFinding> findings;
}

/// Everything wrong between the [declared] Secrets of this tree and what [read] takes out of them.
///
/// [namedElsewhere] is every word the tree writes outside a declaration and outside a `secretKeyRef`
/// block, as [namedTokensIn] reads them. A declared Secret whose name is in it is consumed in a way
/// this check does not model, and is passed over by name rather than refused.
KeyAudit auditExternalSecretKeys({
  required List<DeclaredSecret> declared,
  required List<SecretKeyReference> read,
  required Set<String> namedElsewhere,
}) {
  final Map<String, Set<String>> readKeys = <String, Set<String>>{};
  for (final SecretKeyReference each in read) {
    readKeys.putIfAbsent(each.secret, () => <String>{}).add(each.key);
  }

  final Set<String> judged = <String>{};
  final Map<String, String> passedOver = <String, String>{};
  final List<KeyFinding> found = <KeyFinding>[];

  // FOLDED BY NAME FIRST, because a Secret is a name here and several files declare one.
  // `mongodb-credentials` is written by `apps/mongodb/values-common.yaml` and again by
  // `units/mongodb/values.yaml`, `postfix-dkim-key` once per stage. Judged one declaration at a
  // time, one of them could land in `judged` and the next in `passedOver`, and the run would say
  // both that the Secret was held to the rule and that it was not.
  final Map<String, DeclaredSecret> byName = <String, DeclaredSecret>{};
  for (final DeclaredSecret each in declared) {
    final String? secret = each.secret;
    if (secret == null) {
      passedOver[each.where] =
          'names its target Secret with a template expression, so this tree cannot say which '
          'Secret it declares';
      continue;
    }
    final DeclaredSecret? standing = byName[secret];
    byName[secret] = standing == null
        ? each
        : DeclaredSecret(
            secret: secret,
            keys: <String>{...standing.keys, ...each.keys},
            templated: standing.templated || each.templated,
            unreadableKeys: standing.unreadableKeys + each.unreadableKeys,
            where: standing.where.split(', ').contains(each.where)
                ? standing.where
                : '${standing.where}, ${each.where}',
          );
  }

  for (final String secret in byName.keys.toList()..sort()) {
    final DeclaredSecret each = byName[secret]!;

    if (!each.templated && each.unreadableKeys == 0) {
      for (final SecretKeyReference reference in read) {
        if (reference.secret == secret && !each.keys.contains(reference.key)) {
          found.add(
            UndeclaredKey(
              secret: secret,
              key: reference.key,
              where: reference.where,
              declaredAt: each.where,
            ),
          );
        }
      }
    }

    if (each.templated) {
      passedOver[secret] =
          'its target carries a template, so its secretKey entries are that template\'s inputs and '
          'the Secret\'s keys are the template\'s own';
      continue;
    }
    if (each.unreadableKeys > 0) {
      passedOver[secret] =
          '${each.unreadableKeys} of its secretKey entries are written as a template expression '
          'rather than a name';
      continue;
    }
    if (namedElsewhere.contains(secret)) {
      passedOver[secret] =
          'the tree writes its name outside its own declaration and outside every secretKeyRef, so '
          'its keys travel in a shape this check does not model';
      continue;
    }
    final Set<String> keys = readKeys[secret] ?? <String>{};
    if (keys.isEmpty) {
      passedOver[secret] =
          'no secretKeyRef of this tree names it, so nothing here reads it key by key and its key '
          'set is not legible from this repository';
      continue;
    }

    judged.add(secret);
    for (final String key in each.keys.toList()..sort()) {
      if (!keys.contains(key)) {
        found.add(UnreadKey(secret: secret, key: key, where: each.where));
      }
    }
  }

  return KeyAudit(judged: judged, passedOver: passedOver, findings: found);
}

/// Every word [lines] writes, and every dot-separated part of one.
///
/// A Secret's name is one such word wherever it is written — `secretName: zot-htpasswd`,
/// `existingSecret: grafana-admin-credentials`, `name = "observability-agent-push-credentials"`,
/// `os.environ.get("PG_CREDENTIALS_SECRET", "postgresql-credentials")` — because the punctuation
/// around it is never part of a Kubernetes object name.
Set<String> namedTokensIn(Iterable<String> lines) {
  final Set<String> named = <String>{};
  for (final String line in lines) {
    for (final RegExpMatch each in _word.allMatches(line)) {
      final String word = each.group(0)!;
      named.add(word);
      if (word.contains('.')) {
        named.addAll(word.split('.').where((String part) => part.isNotEmpty));
      }
    }
  }
  return named;
}

final RegExp _word = RegExp(r'[A-Za-z0-9_][A-Za-z0-9_.-]*');

/// What one file of the tree says about the Secrets ExternalSecrets materialize.
final class SecretFileReading {
  /// Records that a file declares [declared], reads [read] and writes [rest] besides.
  const SecretFileReading({required this.declared, required this.read, required this.rest});

  /// The Secrets it declares.
  final List<DeclaredSecret> declared;

  /// The keys it reads through a `secretKeyRef`.
  final List<SecretKeyReference> read;

  /// Every other line of it, with comments removed — where a name written here belongs to a
  /// declared Secret, that Secret is consumed in a way this check does not model.
  final List<String> rest;
}

final RegExp _documentBreak = RegExp(r'^---\s*$');
final RegExp _externalSecretKind = RegExp(r'^kind:\s*ExternalSecret\s*$');
final RegExp _valuesBlock = RegExp(r'^(\s*)externalSecret:\s*$');
final RegExp _keyReference = RegExp(r'^(\s*)(?:-\s+)?secretKeyRef:\s*$');
final RegExp _declaredKey = RegExp(r'^\s*-\s+secretKey:\s*(\S.*?)\s*$');
final RegExp _targetBlock = RegExp(r'^(\s*)target:\s*$');
final RegExp _named = RegExp(r'^\s*name:\s*(\S.*?)\s*$');
final RegExp _keyField = RegExp(r'^\s*key:\s*(\S.*?)\s*$');
final RegExp _targetSecretName = RegExp(r'^\s*targetSecretName:\s*(\S.*?)\s*$');
final RegExp _templateField = RegExp(r'^\s*template:\s*$');
final RegExp _helmComment = RegExp(r'\{\{-?\s*/\*.*?\*/\s*-?\}\}', dotAll: true);

/// What the file at [path] holding [source] says, as [SecretFileReading] describes it.
SecretFileReading readSecretFile({required String path, required String source}) {
  final List<String> lines = commentFreeLines(source);
  final List<bool> taken = List<bool>.filled(lines.length, false);
  final List<DeclaredSecret> declared = <DeclaredSecret>[];
  final List<SecretKeyReference> read = <SecretKeyReference>[];

  for (int start = 0; start < lines.length;) {
    int end = start;
    while (end < lines.length && !_documentBreak.hasMatch(lines[end])) {
      end++;
    }
    final List<String> document = lines.sublist(start, end);
    if (document.any(_externalSecretKind.hasMatch)) {
      declared.add(_templateDeclaration(document, path));
      for (int i = start; i < end; i++) {
        taken[i] = true;
      }
    }
    start = end + 1;
  }

  for (int i = 0; i < lines.length; i++) {
    if (taken[i] || _valuesBlock.firstMatch(lines[i]) == null) {
      continue;
    }
    final int end = _blockEnd(lines, i);
    if (_valuesDeclaration(lines.sublist(i + 1, end), path) case final DeclaredSecret found) {
      declared.add(found);
    }
    for (int each = i; each < end; each++) {
      taken[each] = true;
    }
  }

  for (int i = 0; i < lines.length; i++) {
    if (taken[i] || _keyReference.firstMatch(lines[i]) == null) {
      continue;
    }
    final int end = _blockEnd(lines, i);
    String? secret;
    String? key;
    for (final String line in lines.sublist(i + 1, end)) {
      if (_named.firstMatch(line) case final RegExpMatch found when secret == null) {
        secret = _literal(found.group(1)!);
      }
      if (_keyField.firstMatch(line) case final RegExpMatch found when key == null) {
        key = _literal(found.group(1)!);
      }
    }
    if (secret != null && key != null) {
      read.add(SecretKeyReference(secret: secret, key: key, where: path));
    }
    for (int each = i; each < end; each++) {
      taken[each] = true;
    }
  }

  return SecretFileReading(
    declared: declared,
    read: read,
    rest: <String>[
      for (int i = 0; i < lines.length; i++)
        if (!taken[i]) lines[i],
    ],
  );
}

/// [source] with every comment blanked and every line's trailing carriage return removed, one entry
/// per line of it.
///
/// Both kinds of comment go, and the second is the one that decides how much this check covers. A
/// Secret's name is written in prose all over this tree — `apps/manager/templates/deployment.yaml`
/// names `manager-storage-box`, `manager-webhook` and `manager-cloudflare-dns` in the comments over
/// the env vars that read them — and a reader that counted those as consumption would pass over
/// almost every Secret it is meant to judge. Helm's own `{{- /* … */ -}}` blocks go for the same
/// reason: `apps/service-provisioner/templates/rbac.yaml` opens with one that names two Secrets.
List<String> commentFreeLines(String source) => source
    .replaceAllMapped(_helmComment, (Match each) => '\n' * '\n'.allMatches(each.group(0)!).length)
    .split('\n')
    .map(
      (String line) =>
          _withoutComment(line.endsWith('\r') ? line.substring(0, line.length - 1) : line),
    )
    .toList();

/// [line] up to the `#` that opens its comment, or all of it where none does.
///
/// A `#` inside a quoted scalar opens nothing, and neither does one welded to the word before it.
/// That is what YAML says, and cutting on either would shorten a line that carries a Secret's name
/// and take that Secret out of the judged set without saying so.
String _withoutComment(String line) {
  bool single = false;
  bool double = false;
  for (int i = 0; i < line.length; i++) {
    final String character = line[i];
    if (character == "'" && !double) {
      single = !single;
    } else if (character == '"' && !single) {
      double = !double;
    } else if (character == '#' && !single && !double && (i == 0 || line[i - 1].trim().isEmpty)) {
      return line.substring(0, i);
    }
  }
  return line;
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

/// What [written] stands for, or null where it is composed by a template expression or empty.
String? _literal(String written) {
  final String bare = _unquote(written.trim());
  if (bare.isEmpty || bare.contains('{{')) {
    return null;
  }
  return bare;
}

String _unquote(String written) {
  if (written.length > 1 &&
      (written.startsWith('"') && written.endsWith('"') ||
          written.startsWith("'") && written.endsWith("'"))) {
    return written.substring(1, written.length - 1);
  }
  return written;
}

DeclaredSecret _templateDeclaration(List<String> document, String path) {
  String? secret;
  bool templated = false;
  for (int i = 0; i < document.length; i++) {
    if (_targetBlock.firstMatch(document[i]) == null) {
      continue;
    }
    final int end = _blockEnd(document, i);
    final int level = _childIndent(document, i + 1, end);
    for (final String line in document.sublist(i + 1, end)) {
      if (_indent(line) != level || line.trim().isEmpty) {
        continue;
      }
      if (_named.firstMatch(line) case final RegExpMatch found when secret == null) {
        secret = _literal(found.group(1)!);
      }
      if (_templateField.hasMatch(line)) {
        templated = true;
      }
    }
    break;
  }
  return _declaration(document, secret, templated, path);
}

/// The declaration [block] makes, or null where it makes none.
///
/// **An `externalSecret:` block that names no `targetSecretName` and declares no key is an OVERRIDE
/// LAYER, not a declaration.** Every app here writes its ExternalSecret once in `values-common.yaml`
/// and then repeats the block in `values-dev.yaml`, `values-test.yaml` and `values-prod.yaml`
/// carrying the one field that differs per stage — `vaultPath`. Counting those as three more
/// declarations of a Secret nobody can name would fill what this check reports about its own reach
/// with rows a reader learns nothing from.
DeclaredSecret? _valuesDeclaration(List<String> block, String path) {
  final int level = _childIndent(block, 0, block.length);
  String? secret;
  bool templated = false;
  for (final String line in block) {
    if (line.trim().isEmpty || _indent(line) != level) {
      continue;
    }
    if (_targetSecretName.firstMatch(line) case final RegExpMatch found) {
      secret = _literal(found.group(1)!);
    }
    if (_templateField.hasMatch(line)) {
      templated = true;
    }
  }
  final DeclaredSecret declared = _declaration(block, secret, templated, path);
  if (secret == null && declared.keys.isEmpty && declared.unreadableKeys == 0) {
    return null;
  }
  return declared;
}

DeclaredSecret _declaration(List<String> lines, String? secret, bool templated, String path) {
  final Set<String> keys = <String>{};
  int unreadable = 0;
  for (final String line in lines) {
    if (_declaredKey.firstMatch(line) case final RegExpMatch found) {
      final String? key = _literal(found.group(1)!);
      if (key == null) {
        unreadable++;
      } else {
        keys.add(key);
      }
    }
  }
  return DeclaredSecret(
    secret: secret,
    keys: keys,
    templated: templated,
    unreadableKeys: unreadable,
    where: path,
  );
}

int _childIndent(List<String> lines, int from, int to) {
  for (int i = from; i < to; i++) {
    if (lines[i].trim().isNotEmpty) {
      return _indent(lines[i]);
    }
  }
  return 0;
}
