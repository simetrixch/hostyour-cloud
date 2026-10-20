import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {renderChart} from './render-chart.mjs';

// The sender of every alert mail, and the relay that signs it. A receiver passes SPF and DKIM for a mail only when
// the domain it is sent from has an SPF record for the egress and a key the relay signs with. The relay prepares one key
// file per domain it admits (clusters/inventories/postfix/values-common.yaml), and hostyour-deploy writes that allowlist
// as the platform domain and the unit apex (ansiwise/templates/postfix-values.tpl); both come from the cluster map, as
// does the domain the cluster is reached under. The three differ on every installation, so the stand-in's one value for
// all three cannot tell them apart, and each stage below gets three names of its own.
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
const relayOf = (stage, domains) => renderChart('postfix', [...setsOf(stage, domains),
  '--set', `postfix.config.general.ALLOWED_SENDER_DOMAINS=${domains.platformDomain} ${domains.unitApex}`]);
const statefulSetOf = (relay) => relay.find((d) => d.kind === 'StatefulSet').spec.template.spec;
const allowedDomainsOf = (relay) => relay.find((d) => d.kind === 'ConfigMap' && d.metadata.name === 'postfix').data.ALLOWED_SENDER_DOMAINS.split(/\s+/);
const keyScriptOf = (relay) => statefulSetOf(relay).initContainers.find((c) => c.name === 'fix-dkim-permissions').command.at(-1);
const keyVolumeOf = (relay) => statefulSetOf(relay).volumes.find((v) => v.name === 'dkim-keys-secret');

// What this repository decides about a receiver's verdict on one sender: the relay admits the sender's domain and has a key
// file for it. The published SPF and DKIM records are DNS, which the receiver proof reads after the release.
const senderIsSigned = (sender, allowedDomains, keyFiles) => {
  const domain = sender.slice(sender.indexOf('@') + 1);
  return allowedDomains.includes(domain) && keyFiles.includes(`${domain}.private`);
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
    assert.deepEqual(prepared.files, [`${domains.platformDomain}.private`, `${domains.unitApex}.private`].sort(), `the key files of the ${stage} relay`);
    assert.ok(senderIsSigned(sender, allowedDomainsOf(relay), prepared.files), `PLANTED INNOCENT: the ${stage} alert sender is admitted and holds a key file`);
    assert.ok(senderIsSigned(`customer@${domains.platformDomain}`, allowedDomainsOf(relay), prepared.files), 'PLANTED INNOCENT: the platform domain keeps its key file');
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
  assert.deepEqual(prepared.contents, [KEY, KEY], 'PLANTED INNOCENT: a delivered key is copied to both domain files');
  assert.deepEqual(prepared.modes, [0o600, 0o600]);
  const domains = domainsOf('prod');
  assert.deepEqual(prepared.chowned.sort(), [`101:104 /dkim-keys`, `101:104 /dkim-keys/${domains.platformDomain}.private`, `101:104 /dkim-keys/${domains.unitApex}.private`].sort(), 'the key files and the folder go to opendkim');

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
