/// credentialed-readers — every connection URI this repository writes into a pod's environment
/// carries a password, and that password reaches the pod from a Secret.
///
/// **What a reader is, and why the environment is where they are found.** A pod that talks to one of
/// this platform's backing services is handed the address as an environment variable holding a
/// connection URI — `URL_mongo`, `URL_redis` in `slaves/dbgate/values.yaml`. The credential cannot
/// stand in that URI as text, because the URI is written in a values file that is read by everyone
/// who can read the repository. So the URI names a variable, `$(VAR)`, and a second entry of the
/// SAME env list fills that variable from a `secretKeyRef`. Kubernetes substitutes it in the
/// container before exec, and the password exists only in the pod.
///
/// **Five ways that arrangement fails, and every one of them is silent.** None produces a render
/// error, an ArgoCD refusal or a message naming the cause; all five present as a pod that cannot
/// talk to a database it can see, or as a credential nobody notices is readable:
///
///   * NO CREDENTIAL — the URI carries no userinfo at all. A server that requires one refuses the
///     connection at authentication, each in its own words — redis answers NOAUTH, postgresql and
///     mongodb answer their own — and the pod logs a connection error naming the address, which
///     reads as a database that is down rather than a credential nobody passed. This is the shape
///     hostyour-cloud#64 was filed about: it is what `redis://$(SLAVE_ADDRESS):6379` was, and it was
///     correct until apps/redis began requiring a password.
///   * A LITERAL — the password is written into the values file. It works, which is why it survives:
///     the defect is not that the pod fails but that the credential is in git.
///   * A VARIABLE NOTHING DECLARES — the URI names `$(VAR)` and no entry of the list is called VAR.
///     Kubernetes leaves an unresolvable `$(…)` STANDING, so the pod dials with that text itself as
///     its password.
///   * A VARIABLE DECLARED TOO LATE — Kubernetes expands a variable only from entries BEFORE it in
///     the list. An entry that fills VAR *after* the URI that reads it leaves the same text
///     standing, and the two entries look right beside each other in a diff. The tree states this
///     rule twice in `slaves/dbgate/values.yaml` prose; nothing read it until now.
///   * A VARIABLE FILLED FROM THIS FILE — the entry declaring VAR carries a plain `value:` rather
///     than a `secretKeyRef`. The pod works, and the credential is in git exactly as in the literal
///     above, one indirection further along.
///
/// **WHAT IT DOES NOT REACH.** It reads `env:` lists of this repository's own values, and nothing
/// else. Three things follow, and each of them is a real reader a green run here says nothing about.
/// An upstream sub-chart that takes an address in one value and a Secret in another —
/// `prometheus-redis-exporter.redisAddress` beside `auth.secret`, `prometheus-mongodb-exporter`'s
/// `existingSecret` — carries no URI in an env list of ours and is invisible here. A credential
/// passed as a command-line ARGUMENT rather than an env value is invisible too: `--requirepass
/// $(REDIS_PASSWORD)` in `apps/redis/values-common.yaml` is checked by nothing in this library. And
/// a URI a chart TEMPLATE composes at render time, rather than one written in a values file, is
/// never seen — what is read is the value as it stands on disk.
///
/// It also does not read the Secret. That a `secretKeyRef` names a Secret some ExternalSecret really
/// materializes, that the key exists in it, and that the password inside is the one the server was
/// booted with, are three statements this check makes none of.
library;

/// The URI schemes of a backing service that requires a credential.
///
/// Listed rather than derived, because what makes a scheme belong here is a decision about the
/// SERVER — that it authenticates its callers — and no reading of a URI can tell. A service that
/// starts requiring a password is added here in the same change that makes it require one.
const Set<String> credentialedSchemes = <String>{
  'mongodb',
  'mongodb+srv',
  'postgres',
  'postgresql',
  'redis',
  'rediss',
};

/// One entry of one container's env list, as a values file writes it.
final class EnvEntry {
  /// Records an entry called [name] holding [value], where [fromSecret] says its value is taken
  /// from a `secretKeyRef` rather than written here.
  const EnvEntry({required this.name, this.value, required this.fromSecret});

  /// The variable's name, which is what a `$(…)` elsewhere in the list refers to.
  final String name;

  /// The literal value as the file writes it, or null where the entry has a `valueFrom`.
  final String? value;

  /// Whether the entry's value comes from a `secretKeyRef`.
  final bool fromSecret;
}

/// One env list of one file, in the order the file states it.
///
/// The ORDER is part of the subject and not presentation: Kubernetes expands `$(VAR)` only from
/// entries that stand before the one reading it, so a list sorted on the way in would report a
/// working pod and pass a broken one.
final class EnvList {
  /// Records that the file at [where] states [entries], in file order.
  const EnvList({required this.where, required this.entries});

  /// The file somebody has to open, as a path relative to the repository.
  final String where;

  /// The entries, in the order they stand.
  final List<EnvEntry> entries;
}

/// A URI written into an env list, and what it carries as a password.
final class ReaderUri {
  /// Records that a URI of [scheme] names [credential] as its password — null where it names none,
  /// and [literal] where the password is written out rather than referred to.
  const ReaderUri({required this.scheme, this.credential, this.literal = false});

  /// The URI's scheme, which is what says whether a credential is required at all.
  final String scheme;

  /// The variable name a `$(…)` password refers to, or null where the URI carries no password or
  /// carries a literal one.
  final String? credential;

  /// Whether the password is written out in the file rather than referred to.
  final bool literal;
}

/// Something wrong with how a reader of a backing service is credentialed.
sealed class CredentialFinding {
  /// The file somebody has to open.
  String get where;

  /// The env entry the finding is about.
  String get entry;
}

/// A URI against a service that requires a password, carrying none.
final class UncredentialedReader implements CredentialFinding {
  /// Records that [entry] in [where] dials a [scheme] service with no password.
  const UncredentialedReader(this.where, this.entry, this.scheme);

  @override
  final String where;

  @override
  final String entry;

  /// The scheme, which is what says a password was required.
  final String scheme;

  @override
  String toString() =>
      '$where env "$entry" is a $scheme:// URI carrying no password, and a $scheme server that '
      'requires one refuses the connection at authentication — the pod reaches the address and is '
      'turned away at it, which reads in its log as a database that is down rather than a '
      'credential nobody passed';
}

/// A password written out in the values file.
final class LiteralCredential implements CredentialFinding {
  /// Records that [entry] in [where] carries its password as text.
  const LiteralCredential(this.where, this.entry);

  @override
  final String where;

  @override
  final String entry;

  @override
  String toString() =>
      '$where env "$entry" writes its password out as text — it works, which is the whole trouble '
      'with it: nothing fails, and the credential is in git for everyone who can read the '
      'repository. It belongs in a \$(VAR) filled from a secretKeyRef, like every other one here';
}

/// A `$(VAR)` no entry of the list declares.
final class UnfilledCredential implements CredentialFinding {
  /// Records that [entry] in [where] reads [variable], which the list never declares.
  const UnfilledCredential(this.where, this.entry, this.variable);

  @override
  final String where;

  @override
  final String entry;

  /// The variable the URI reads.
  final String variable;

  @override
  String toString() =>
      '$where env "$entry" reads \$($variable) and no entry of that env list is called "$variable" '
      "— Kubernetes leaves an unresolvable \$(…) STANDING, so the pod dials with the characters "
      '"\$($variable)" as its password and the values file looks correct';
}

/// A `$(VAR)` declared after the URI that reads it.
final class LateCredential implements CredentialFinding {
  /// Records that [entry] in [where] reads [variable], which the list declares further down.
  const LateCredential(this.where, this.entry, this.variable);

  @override
  final String where;

  @override
  final String entry;

  /// The variable the URI reads.
  final String variable;

  @override
  String toString() =>
      '$where env "$entry" reads \$($variable) and the entry declaring "$variable" stands AFTER it '
      '— Kubernetes expands a variable only from entries before the one reading it, so this leaves '
      'the characters "\$($variable)" standing exactly as an undeclared variable would, and the two '
      'entries read correctly beside each other in a diff';
}

/// A `$(VAR)` filled from something other than a Secret.
final class UnbackedCredential implements CredentialFinding {
  /// Records that [entry] in [where] reads [variable], which the list fills without a Secret.
  const UnbackedCredential(this.where, this.entry, this.variable);

  @override
  final String where;

  @override
  final String entry;

  /// The variable the URI reads.
  final String variable;

  @override
  String toString() =>
      '$where env "$entry" reads \$($variable) and the entry declaring "$variable" fills it without '
      'a secretKeyRef — the password reaches the pod from this file rather than from a Secret, '
      'which is the literal above wearing one more indirection';
}

final RegExp _uri = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://([^@/]*)@?');
final RegExp _variable = RegExp(r'^\$\(([A-Za-z_][A-Za-z0-9_]*)\)$');

/// What [written] is, as far as a credentialed reader goes, or null where it is no such URI.
///
/// A value that composes the ADDRESS from a `$(…)` — `redis://user:$(PW)@$(HOST):6379` — is read
/// the same as one naming the host outright: what is being read is the userinfo, and the host half
/// is nothing this check has an opinion about.
ReaderUri? readerUriIn(String written) {
  final RegExpMatch? match = _uri.firstMatch(written.trim());
  if (match == null) {
    return null;
  }
  final String scheme = match.group(1)!.toLowerCase();
  if (!credentialedSchemes.contains(scheme)) {
    return null;
  }
  // Group 2 holds everything up to the first `@` or `/`. With no `@` in the URI that is the HOST,
  // not a userinfo, and the reader carries no credential at all.
  if (!written.trim().startsWith('$scheme://${match.group(2)}@')) {
    return ReaderUri(scheme: scheme);
  }
  final String userinfo = match.group(2)!;
  final int colon = userinfo.indexOf(':');
  if (colon < 0) {
    // A user with no password. Against a server that requires one this is the same refusal as no
    // userinfo at all, so it is reported as the same finding.
    return ReaderUri(scheme: scheme);
  }
  final String password = userinfo.substring(colon + 1);
  final RegExpMatch? reference = _variable.firstMatch(password);
  if (reference == null) {
    return ReaderUri(scheme: scheme, literal: true);
  }
  return ReaderUri(scheme: scheme, credential: reference.group(1));
}

/// Every way the readers in [lists] are not credentialed out of a Secret.
///
/// Each list is walked in file order, so what a URI may refer to is exactly what stands before it —
/// the rule Kubernetes applies, and the reason this takes an ordered list rather than a map.
List<CredentialFinding> auditCredentialedReaders({required List<EnvList> lists}) {
  final List<CredentialFinding> found = <CredentialFinding>[];
  for (final EnvList list in lists) {
    final Set<String> declaredLater = <String>{for (final EnvEntry each in list.entries) each.name};
    final Map<String, EnvEntry> declaredBefore = <String, EnvEntry>{};
    for (final EnvEntry each in list.entries) {
      final String? value = each.value;
      final ReaderUri? uri = value == null ? null : readerUriIn(value);
      if (uri != null) {
        if (uri.literal) {
          found.add(LiteralCredential(list.where, each.name));
        } else if (uri.credential == null) {
          found.add(UncredentialedReader(list.where, each.name, uri.scheme));
        } else if (declaredBefore[uri.credential!] case final EnvEntry filler) {
          if (!filler.fromSecret) {
            found.add(UnbackedCredential(list.where, each.name, uri.credential!));
          }
        } else if (declaredLater.contains(uri.credential)) {
          found.add(LateCredential(list.where, each.name, uri.credential!));
        } else {
          found.add(UnfilledCredential(list.where, each.name, uri.credential!));
        }
      }
      declaredBefore[each.name] = each;
    }
  }
  return found;
}

/// Every env list [values] holds, wherever it stands in the tree, as lists standing at [where].
///
/// A values file nests an env list wherever the sub-chart that reads it stands, so what is searched
/// for is the SHAPE — a key `env` holding a list whose items are maps with a `name` — at any depth.
/// A key called `env` holding anything else is the platform-wide `global.env: dev|test|prod` string
/// and is passed over, which is the same distinction `charts/deployment` states in its own template.
List<EnvList> envListsIn({required String where, required Object? values}) {
  final List<EnvList> found = <EnvList>[];
  void walk(Object? node) {
    if (node is Map) {
      for (final MapEntry<Object?, Object?> each in node.entries) {
        if (each.key == 'env' && each.value is List) {
          final List<EnvEntry> entries = _entriesIn(each.value! as List<Object?>);
          if (entries.isNotEmpty) {
            found.add(EnvList(where: where, entries: entries));
          }
        }
        walk(each.value);
      }
    } else if (node is List) {
      for (final Object? each in node) {
        walk(each);
      }
    }
  }

  walk(values);
  return found;
}

List<EnvEntry> _entriesIn(List<Object?> items) {
  final List<EnvEntry> entries = <EnvEntry>[];
  for (final Object? item in items) {
    if (item is! Map) {
      continue;
    }
    final Object? name = item['name'];
    if (name is! String) {
      continue;
    }
    final Object? from = item['valueFrom'];
    final bool fromSecret = from is Map && from['secretKeyRef'] != null;
    final Object? value = item['value'];
    entries.add(
      EnvEntry(
        name: name,
        value: value is String ? value : (value == null ? null : '$value'),
        fromSecret: fromSecret,
      ),
    );
  }
  return entries;
}
