/// A line of an ExternalSecret's spec that the platform-wide secret delivery rule fixes.
///
/// TWO LINES, ONE SENTENCE. A secret reaches a cluster in exactly two moments — when it is
/// DEPLOYED, and when its target Secret is DELETED — and nothing on this platform reads Vault on a
/// timer. `refreshPolicy: OnChange` is what makes both halves true by contract: external-secrets
/// re-syncs when the CR changes and creates the target Secret when it is absent, independent of the
/// interval. `refreshInterval: "0"` stands beside it because OnChange ignores it and a stated zero
/// is what lets a reader see at a glance that nothing here polls.
///
/// NEITHER VALUE IS THE DEFAULT. The default policy is `Periodic`, and behind `Periodic` the same
/// `"0"` means the opposite of what it means here — the secret is created once and never updated
/// again, so a chart change that alters the CR does not re-read Vault at all. The two values are
/// therefore read together or not at all, which is why they are one rule and not two.
///
/// AND THEY ARE LITERALS. A `{{ .Values.… }}` in either position is a per-app override, and an
/// override is how one namespace ends up on a different delivery model than every other while every
/// rendered manifest still looks orderly. The difference stays invisible until somebody writes a new
/// value into Vault behind it and the pods of that one namespace pick it up on a schedule nobody
/// remembered.
enum RefreshField {
  /// What decides WHEN external-secrets acts at all.
  refreshPolicy('refreshPolicy', 'OnChange'),

  /// The interval it would poll on, stated as zero beside a policy that ignores it.
  refreshInterval('refreshInterval', '"0"');

  const RefreshField(this.key, this.literal);

  /// The key, as an ExternalSecret's spec writes it.
  final String key;

  /// The one value it is fixed to, as it stands in the file — quotes included, because `"0"` and
  /// `0` are two different scalars and only one of them is what these manifests carry.
  final String literal;

  /// Whether [value] — what stands after the colon on the line — is that literal and nothing else.
  ///
  /// A trailing comment is still the literal: it changes no byte a cluster reads. A template
  /// expression is not, and neither is a second value beside it.
  bool isStatedLiterallyBy(String value) =>
      RegExp('^${RegExp.escape(literal)}[ \\t]*(#.*)?\$').hasMatch(value.trim());

  /// The pattern that finds the line this field is stated on. Group 1 is what stands after the
  /// colon.
  ///
  /// A key indented behind a `#` never matches, so the prose above these lines in
  /// charts/external-secret/templates/externalsecret.yaml — which quotes both values while
  /// explaining them — is read as the comment it is.
  RegExp get statement => RegExp('^[ \\t]*$key[ \\t]*:(.*)\$');

  /// What a person needs to read in order to act on a finding about this field.
  String get because => switch (this) {
    RefreshField.refreshPolicy =>
      'OnChange delivers on deploy and on target-Secret deletion, by contract and independent of '
          'the interval; the default is Periodic, which reads Vault on a timer',
    RefreshField.refreshInterval =>
      'a stated "0" is what shows at a glance that nothing polls; behind the default Periodic the '
          'same "0" means the opposite — created once, then never updated again',
  };
}
