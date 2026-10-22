import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {renderChart} from './render-chart.mjs';

// The sender of every alert mail, and the relay that signs it. A receiver passes SPF and DKIM for a mail only when
// the domain it is sent from has an SPF record for the egress and a key the relay signs with. The relay prepares a key
// file for the unit apex alone (clusters/inventories/postfix/values-common.yaml): the platform domain's mail is signed by
// the mail service the relay hands it to. hostyour-deploy writes the allowlist as the platform domain and the unit apex
// (ansiwise/templates/postfix-values.tpl); both come from the cluster map, as does the domain the cluster is reached
// under. The three differ on every installation, so the stand-in's one value for all three cannot tell them apart, and
// each stage below gets three names of its own.
const STAGES = ['dev', 'test', 'prod'];
const domainsOf = (stage) => ({domain: `cluster.${stage}.invalid`, platformDomain: `platform.${stage}.invalid`, unitApex: `apex.${stage}.invalid`});
const setsOf = (stage, {domain, platformDomain, unitApex}) => ['--set', `global.env=${stage}`, '--set', `global.domain=${domain}`,
  '--set', `global.platformDomain=${platformDomain}`, '--set', `global.unitApex=${unitApex}`];
const smtpFromOf = (stage, domains) => {
  const rendered = renderChart('observability', ['--api-versions', 'monitoring.coreos.com/v1alpha1', ...setsOf(stage, domains)]);
  const alertmanager = rendered.find((d) => d.kind === 'Secret' && d.metadata.name === 'alertmanager-observability-alertmanager');
  const config = execFileSync('yq', ['-o=json', '.'], {input: Buffer.from(alertmanager.data['alertmanager.yaml'], 'base64').toString('utf8'), encoding: 'utf8'});
  return JSON.parse(config).global.smtp_from;
};
// The stand-in renders the values of prod only, so the stage's own DKIM selector is read from its file and handed in.
const selectorOf = (stage) => execFileSync('yq', ['.postfix.config.general.DKIM_SELECTOR', `clusters/inventories/postfix/values-${stage}.yaml`], {encoding: 'utf8'}).trim();
const relayOf = (stage, domains, extra = []) => renderChart('postfix', [...setsOf(stage, domains),
  '--set', `postfix.config.general.ALLOWED_SENDER_DOMAINS=${domains.platformDomain} ${domains.unitApex}`,
  '--set', `postfix.config.general.DKIM_SELECTOR=${selectorOf(stage)}`, ...extra]);
const statefulSetOf = (relay) => relay.find((d) => d.kind === 'StatefulSet').spec.template.spec;
const relayLabelsOf = (relay) => relay.find((d) => d.kind === 'StatefulSet').spec.template.metadata.labels;
const configMapOf = (relay) => relay.find((d) => d.kind === 'ConfigMap' && d.metadata.name === 'postfix').data;
const allowedDomainsOf = (relay) => configMapOf(relay).ALLOWED_SENDER_DOMAINS.split(/\s+/);
const keyScriptOf = (relay) => statefulSetOf(relay).initContainers.find((c) => c.name === 'fix-dkim-permissions').command.at(-1);
const keyVolumeOf = (relay) => statefulSetOf(relay).volumes.find((v) => v.name === 'dkim-keys-secret');

// What this repository decides about a receiver's verdict on one sender: the relay admits the sender's domain and has a key
// file for it. The published SPF and DKIM records are DNS, which the receiver proof reads after the release.
const senderIsSigned = (sender, allowedDomains, keyFiles) => {
  const domain = sender.slice(sender.indexOf('@') + 1);
  return allowedDomains.includes(domain) && keyFiles.includes(`${domain}.private`);
};

// `postconf -d parent_domain_matches_subdomains` in boky/postfix:5.1.0, what the relay applies where its ConfigMap sets none.
const POSTFIX_DEFAULT_PARENT_DOMAIN_MATCHES_SUBDOMAINS = 'debug_peer_list,fast_flush_domains,mynetworks,permit_mx_backup_networks,qmqpd_authorized_clients,relay_domains,smtpd_access_maps';
const parentDomainMatchesOf = (relay) => (configMapOf(relay).POSTFIX_parent_domain_matches_subdomains ?? POSTFIX_DEFAULT_PARENT_DOMAIN_MATCHES_SUBDOMAINS).split(/[\s,]+/);

// The rule access(5) states for the allowlist the image puts at RCPT TO: a `domain.tld` row admits the domain, and its subdomains
// only while smtpd_access_maps is listed in parent_domain_matches_subdomains. It models that rule, not Postfix: Postfix itself
// is read live on the master after the release.
const senderIsAdmitted = (sender, allowedDomains, parentDomainMatches) => {
  const domain = sender.slice(sender.indexOf('@') + 1);
  return allowedDomains.some((row) => domain === row || (domain.endsWith(`.${row}`) && parentDomainMatches.includes('smtpd_access_maps')));
};

// Kubernetes' reading of a selector: every label it names stands on the object.
const selects = (selector, labels) => Object.entries(selector.matchLabels ?? {}).every(([name, value]) => labels[name] === value);
const policyOf = (relay) => relay.find((d) => d.kind === 'NetworkPolicy' && d.metadata.name === 'postfix-access');
const servicesOf = (relay) => relay.filter((d) => d.kind === 'Service');
const hooksOf = (relay) => relay.filter((d) => d.kind === 'Job' && d.metadata.name === 'dkim-testkey');
// A client in a namespace with these labels reaches the relay on this port: a rule of the policy that names the port and a
// namespaceSelector without a podSelector.
const admitsClient = (policy, namespaceLabels, port) => policy.spec.ingress.some((rule) =>
  (rule.ports ?? []).some((p) => p.protocol === 'TCP' && p.port === port) &&
  (rule.from ?? []).some((peer) => peer.namespaceSelector && !peer.podSelector && selects(peer.namespaceSelector, namespaceLabels)));

// What the hook of the relay's Application must be to prove the key: the faults of one render, none when it is as intended.
// The relay's key is root's 0400 file in a Secret volume, read by the one uid that owns it, so a uid, a mode or an fsGroup that
// differs is a hook that cannot read the key it tests.
const hookFaults = (relay, unitApex) => {
  const hooks = hooksOf(relay);
  if (hooks.length !== 1) return [`${hooks.length} Jobs named dkim-testkey, not one`];
  const [job] = hooks;
  const pod = job.spec.template.spec;
  const [container] = pod.containers;
  const volume = pod.volumes?.find((v) => v.secret?.secretName === 'postfix-dkim-key');
  const mount = container.volumeMounts?.find((m) => m.name === volume?.name);
  const faults = [];
  const expect = (ok, fault) => { if (!ok) faults.push(fault); };
  expect(job.metadata.annotations['argocd.argoproj.io/hook'] === 'PostSync', 'is not a PostSync hook');
  expect(job.metadata.annotations['argocd.argoproj.io/hook-delete-policy'] === 'BeforeHookCreation', 'does not delete itself before it is created again');
  expect(JSON.stringify(container.command) === JSON.stringify(['opendkim-testkey', '-d', unitApex, '-s', configMapOf(relay).DKIM_SELECTOR, '-k', '/dkim-source/dkim-private-key', '-vvv']), `runs ${container.command}`);
  expect(container.image === statefulSetOf(relay).containers.find((c) => c.name === 'postfix').image, `runs ${container.image}, not the relay's image`);
  expect(JSON.stringify(volume?.secret.items) === JSON.stringify([{key: 'dkim-private-key', path: 'dkim-private-key'}]), 'does not mount the key item of postfix-dkim-key');
  expect(volume?.secret.defaultMode === 0o400, 'does not mount the key at mode 0400');
  expect(mount?.mountPath === '/dkim-source' && mount.readOnly === true, 'does not mount the key read only at /dkim-source');
  expect(container.securityContext?.runAsUser === 0, `runs as uid ${container.securityContext?.runAsUser}, which cannot read a root-owned 0400 key file`);
  expect(pod.securityContext?.fsGroup === undefined, 'sets an fsGroup');
  return faults;
};

// Runs the init container script of a rendered relay on this machine, with its two volume paths pointed into a scratch
// folder and `chown`, which needs root, replaced by a recorder; `failing` names a command whose stand-in fails. Everything
// else is the script's own. `key` is the content of the delivered key file, or undefined when no file was delivered.
const prepareKeys = (script, key, failing = null) => {
  const scratch = mkdtempSync(join(tmpdir(), 'relay-key-'));
  try {
    const [source, keys, bin, chowned] = ['source', 'keys', 'bin', 'chowned'].map((name) => join(scratch, name));
    for (const dir of [source, keys, bin]) mkdirSync(dir);
    for (const command of ['chown', 'cp', 'chmod']) {
      if (command === failing) writeFileSync(join(bin, command), '#!/bin/sh\nexit 1\n', {mode: 0o755});
      else if (command === 'chown') writeFileSync(join(bin, command), `#!/bin/sh\necho "$@" >> '${chowned}'\n`, {mode: 0o755});
    }
    writeFileSync(chowned, '');
    if (key !== undefined) writeFileSync(join(source, 'dkim-private-key'), key);
    const run = spawnSync('sh', ['-c', script.replaceAll('/dkim-source', source).replaceAll('/dkim-keys', keys)],
      {env: {...process.env, PATH: `${bin}:${process.env.PATH}`}, encoding: 'utf8'});
    const files = readdirSync(keys).sort();
    return {status: run.status, stderr: run.stderr, files, contents: files.map((f) => readFileSync(join(keys, f), 'utf8')),
      modes: files.map((f) => statSync(join(keys, f)).mode & 0o777), chowned: readFileSync(chowned, 'utf8').split('\n').filter(Boolean)
        .map((line) => line.replaceAll(keys, '/dkim-keys'))};
  } finally {
    rmSync(scratch, {recursive: true, force: true});
  }
};
const KEY = 'a private key, in the test never a real one\n';

test('every stage sends alert mail from its unit apex, a domain the relay admits and holds a key file for', () => {
  for (const stage of STAGES) {
    const domains = domainsOf(stage);
    const sender = smtpFromOf(stage, domains);
    assert.equal(sender, `alertmanager-${stage}@${domains.unitApex}`, `the ${stage} sender`);
    const relay = relayOf(stage, domains);
    const prepared = prepareKeys(keyScriptOf(relay), KEY);
    assert.equal(prepared.status, 0, prepared.stderr);
    assert.deepEqual(prepared.files, [`${domains.unitApex}.private`], `the key files of the ${stage} relay`);
    assert.ok(senderIsSigned(sender, allowedDomainsOf(relay), prepared.files), `PLANTED INNOCENT: the ${stage} alert sender is admitted and holds a key file`);
    assert.ok(!senderIsSigned(`customer@${domains.platformDomain}`, allowedDomainsOf(relay), prepared.files), 'the relay holds no key file for the platform domain: the mail service it hands that mail to signs it');
    const older = `alertmanager-${stage}@mail.${domains.domain}`;
    assert.ok(!senderIsSigned(older, allowedDomainsOf(relay), prepared.files), 'PLANTED DEFECT: a sender on mail.<the cluster domain> has neither admission nor a key file');
    assert.ok(!senderIsSigned(sender, allowedDomainsOf(relay), [`${domains.domain}.private`]), 'PLANTED DEFECT: a key file named for the cluster domain signs nothing');
    assert.ok(!senderIsSigned(sender, [domains.platformDomain], prepared.files), 'PLANTED DEFECT: an allowlist without the unit apex refuses the alert sender');
    assert.ok(!senderIsSigned(sender, allowedDomainsOf(relay), [`${domains.platformDomain}.private`]), 'PLANTED DEFECT: an admitted domain without its key file is sent unsigned');
  }
});

test('an installation without global.unitApex gets no alert sender, and the render names the key', () => {
  assert.throws(() => smtpFromOf('prod', {...domainsOf('prod'), unitApex: ''}), /global\.unitApex-is-required/);
});

test('the relay requires its key Secret, and a key it cannot prepare ends the init container', () => {
  const relay = relayOf('prod', domainsOf('prod'));
  const volume = keyVolumeOf(relay);
  assert.equal(volume.secret.secretName, 'postfix-dkim-key');
  const isRequired = (v) => v.secret.optional !== true;
  assert.ok(isRequired(volume), 'PLANTED INNOCENT: the Secret is required, so a missing one holds the pod back instead of letting it send unsigned mail');
  assert.ok(!isRequired({secret: {...volume.secret, optional: true}}), 'PLANTED DEFECT: an optional Secret lets the relay start without its key');
  assert.deepEqual(volume.secret.items, [{key: 'dkim-private-key', path: 'dkim-private-key'}]);

  const script = keyScriptOf(relay);
  const prepared = prepareKeys(script, KEY);
  assert.equal(prepared.status, 0, prepared.stderr);
  assert.deepEqual(prepared.contents, [KEY], 'PLANTED INNOCENT: a delivered key is copied to the unit apex file');
  assert.deepEqual(prepared.modes, [0o600]);
  const domains = domainsOf('prod');
  assert.deepEqual(prepared.chowned.sort(), [`101:104 /dkim-keys`, `101:104 /dkim-keys/${domains.unitApex}.private`].sort(), 'the key file and the folder go to opendkim');

  for (const [name, key] of [['no key file', undefined], ['an empty key file', '']]) {
    const stopped = prepareKeys(script, key);
    assert.notEqual(stopped.status, 0, `${name} stops the init container`);
    assert.match(stopped.stderr, /dkim-private-key is missing or empty/, name);
    assert.deepEqual(stopped.files, [], `${name} leaves no key file`);
  }
  for (const command of ['cp', 'chown', 'chmod']) {
    assert.notEqual(prepareKeys(script, KEY, command).status, 0, `a failed ${command} stops the init container`);
  }
  assert.equal(prepareKeys(script.replace('set -eu\n', ''), KEY, 'chown').status, 0, 'PLANTED DEFECT: without set -e a failed chown goes unnoticed');
  assert.equal(prepareKeys(script.replace('[ -s ', '[ -f '), '').status, 0, 'PLANTED DEFECT: a test for the file instead of its content lets an empty key through');
});

test('the relay refuses a sender at a subdomain of its domains or at a foreign domain, and admits the alert sender', () => {
  for (const stage of STAGES) {
    const domains = domainsOf(stage);
    const relay = relayOf(stage, domains);
    const allowed = allowedDomainsOf(relay);
    assert.deepEqual(allowed.sort(), [domains.platformDomain, domains.unitApex].sort(), `the ${stage} relay admits both its domains`);
    const parentDomainMatches = parentDomainMatchesOf(relay);
    assert.ok(!parentDomainMatches.includes('smtpd_access_maps'), 'the allowlist rows match the domain and not its subdomains');
    const alert = `alertmanager-${stage}@${domains.unitApex}`;
    const subdomain = `alertmanager-${stage}@mail.${domains.unitApex}`;
    assert.ok(senderIsAdmitted(alert, allowed, parentDomainMatches), 'PLANTED INNOCENT: the alert sender is admitted');
    assert.ok(senderIsAdmitted(`customer@${domains.platformDomain}`, allowed, parentDomainMatches), 'PLANTED INNOCENT: the platform domain is admitted');
    assert.ok(!senderIsAdmitted(subdomain, allowed, parentDomainMatches), 'PLANTED DEFECT: a sender at a subdomain of the unit apex is refused');
    assert.ok(!senderIsAdmitted('probe@example.invalid', allowed, parentDomainMatches), 'PLANTED DEFECT: a sender at a foreign domain is refused');
    const withoutSetting = structuredClone(relay);
    delete configMapOf(withoutSetting).POSTFIX_parent_domain_matches_subdomains;
    assert.ok(senderIsAdmitted(subdomain, allowed, parentDomainMatchesOf(withoutSetting)), 'PLANTED DEFECT: the setting removed leaves the Postfix default, which admits the subdomain, so the refusal above goes red');
  }
});

test('the relay fence selects the relay pod and the hook pod, and admits the namespaces that send and no other', () => {
  const relay = relayOf('prod', domainsOf('prod'));
  const policy = policyOf(relay);
  const relayLabels = relayLabelsOf(relay);
  const [hook] = hooksOf(relay);
  assert.notDeepEqual(policy.spec.podSelector.matchLabels ?? {}, {}, 'the fence names a label: an empty selector is every pod of the namespace');
  assert.ok(selects(policy.spec.podSelector, relayLabels), 'the fence selects the relay pod');
  assert.ok(selects(policy.spec.podSelector, hook.spec.template.metadata.labels), 'the fence selects the hook pod, which mounts the key');
  assert.ok(!selects({matchLabels: {'app.kubernetes.io/name': 'mail'}}, relayLabels), 'PLANTED DEFECT: the selector of the mail chart name selects no pod');

  assert.ok(admitsClient(policy, {'kubernetes.io/metadata.name': 'observability'}, 587), 'PLANTED INNOCENT: Alertmanager\'s namespace reaches the relay');
  assert.ok(admitsClient(policy, {'platform/postfix-consumer': 'true'}, 587), 'PLANTED INNOCENT: a namespace of a unit that attested the relay reaches it');
  assert.ok(!admitsClient(policy, {'kubernetes.io/metadata.name': 'default'}, 587), 'PLANTED DEFECT: a namespace the policy does not name gets no connection');
  assert.ok(!admitsClient(policy, {'platform/db-consumer': 'true'}, 587), 'PLANTED DEFECT: a namespace that only consumes a database gets no connection');
  assert.ok(!admitsClient(policy, {'kubernetes.io/metadata.name': 'observability'}, 25), 'PLANTED DEFECT: the relay listens for clients on 587 only');
});

test('no Service hands the relay port to the hook pod', () => {
  const relay = relayOf('prod', domainsOf('prod'));
  const services = servicesOf(relay);
  const [hook] = hooksOf(relay);
  const handedTo = (labels) => services.filter((service) => selects({matchLabels: service.spec.selector}, labels)).map((service) => service.metadata.name);
  assert.deepEqual(handedTo(relayLabelsOf(relay)), services.map((service) => service.metadata.name), 'PLANTED INNOCENT: every Service of the relay selects the relay pod');
  assert.deepEqual(handedTo(hook.spec.template.metadata.labels), [], 'no Service selects the hook pod');
  assert.notDeepEqual(handedTo(hook.metadata.labels), [], 'PLANTED DEFECT: a hook pod labeled with common.labels, as its Job is, is selected by the relay Services');
});

test('every sync tests the key the relay signs with against the record of the unit apex', () => {
  for (const stage of STAGES) {
    const domains = domainsOf(stage);
    const relay = relayOf(stage, domains);
    assert.equal(selectorOf(stage), stage, `the ${stage} relay signs with the selector ${stage}`);
    assert.deepEqual(hookFaults(relay, domains.unitApex), [], `PLANTED INNOCENT: the ${stage} hook`);

    const planted = (name, change, fault) => {
      const copy = structuredClone(relay);
      change(hooksOf(copy)[0]);
      assert.match(hookFaults(copy, domains.unitApex).join('; '), fault, `PLANTED DEFECT: ${name}`);
    };
    const command = (job) => job.spec.template.spec.containers[0].command;
    planted('a hook for the platform domain', (job) => { command(job)[2] = domains.platformDomain; }, /runs /);
    planted('a hook for another selector', (job) => { command(job)[4] = 'other'; }, /runs /);
    planted('a hook for another key path', (job) => { command(job)[6] = '/dkim-source/other'; }, /runs /);
    planted('a hook of another image', (job) => { job.spec.template.spec.containers[0].image = 'boky/postfix:latest'; }, /not the relay's image/);
    planted('a hook that is no PostSync', (job) => { job.metadata.annotations['argocd.argoproj.io/hook'] = 'PreSync'; }, /not a PostSync hook/);
    planted('a hook that stays after its run', (job) => { delete job.metadata.annotations['argocd.argoproj.io/hook-delete-policy']; }, /does not delete itself/);
    planted('a hook that mounts the key at another mode', (job) => { job.spec.template.spec.volumes[0].secret.defaultMode = 0o440; }, /mode 0400/);
    planted('a hook with a non-root uid and the 0400 item', (job) => { job.spec.template.spec.containers[0].securityContext.runAsUser = 101; }, /uid 101/);
    planted('a hook with an fsGroup', (job) => { job.spec.template.spec.securityContext = {fsGroup: 101}; }, /fsGroup/);
    assert.deepEqual(hookFaults(relay.filter((d) => d.kind !== 'Job'), domains.unitApex), ['0 Jobs named dkim-testkey, not one'], 'PLANTED DEFECT: no hook');
  }
});

test('an installation without global.unitApex renders no relay, so no hook tests a record of no domain', () => {
  assert.throws(() => relayOf('prod', {...domainsOf('prod'), unitApex: ''}), /global\.unitApex/);
});
