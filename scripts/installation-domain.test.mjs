import {strict as assert} from 'node:assert';
import {spawnSync} from 'node:child_process';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';
import {planInstallation, installedIngressHosts} from '../lifecycle/plan-installation-domain.mjs';

const fixture = () => [{file: 'clusters/active/master.old.example.yaml', map: {
  role: 'master', stage: 'prod', release: 'unchanged-pin', global: {
    domain: 'master.old.example', clusterName: 'standing-name', booksCluster: 'master.old.example',
    buildPlane: 'master.old.example', unitApex: 'old.example', platformDomain: 'mail.example',
    endpoints: {registry: {host: 'zot.master.old.example'}, vault: {url: 'https://vault.master.old.example', privateAddress: '100.64.0.1'},
      idp: {url: 'https://external.example/issuer/'}, mail: {host: 'mail.old.example', password: 'never-emitted'}}
  }
}}];

test('map only hostname boundaries, retain data/keys/mail and original inventory', () => {
  const maps = fixture(), before = JSON.stringify(maps);
  const plan = planInstallation(maps, 'old.example', 'new.example', ['argo.master.old.example', 'myold.example', '*.nested.old.example', 'customer.example']);
  assert.equal(JSON.stringify(maps), before);
  assert.equal(plan.clusterCount, 1);
  assert.equal(plan.changes[0].clusterName, 'standing-name');
  assert.equal(plan.cutoverReady, false);
  assert.deepEqual(plan.preservedHosts, ['customer.example', 'myold.example']);
  assert.ok(plan.hosts.some(row => row.before === '*.nested.old.example' && row.after === '*.nested.new.example'));
  assert.ok(plan.changes[0].fields.some(row => row.before === 'https://vault.master.old.example' && row.after === 'https://vault.master.new.example'));
  for (const forbidden of ['never-emitted', '100.64.0.1', 'unchanged-pin', 'mail.old.example']) assert.ok(!JSON.stringify(plan).includes(forbidden));
  assert.ok(!plan.changes[0].fields.some(row => row.path === 'global.endpoints.idp.url'));
  const upper = fixture(); upper[0].map.global.endpoints.vault.url = 'https://VAULT.master.old.example:443/';
  assert.ok(planInstallation(upper, 'old.example', 'new.example').changes[0].fields.some(row => row.after === 'https://vault.master.new.example:443/'));
});

test('reject zone overlap, malformed/conflicting maps and credential-bearing URLs', () => {
  assert.throws(() => planInstallation(fixture(), 'old.example', 'nested.old.example'));
  const wrong = fixture(); wrong[0].map.global.domain = 'other.old.example';
  assert.throws(() => planInstallation(wrong, 'old.example', 'new.example'));
  assert.throws(() => planInstallation([...fixture(), ...fixture()], 'old.example', 'new.example'));
  const secret = fixture(); secret[0].map.global.endpoints.vault.url = 'https://user:secret@vault.old.example';
  assert.throws(() => planInstallation(secret, 'old.example', 'new.example'), /no credentials/);
  const query = fixture(); query[0].map.global.endpoints.vault.url = 'https://vault.old.example/?token=secret';
  assert.throws(() => planInstallation(query, 'old.example', 'new.example'), /no credentials/);
  const malformed = fixture(); malformed[0].map.global.unitApex = 'bad/old.example';
  assert.throws(() => planInstallation(malformed, 'old.example', 'new.example'));
  assert.throws(() => planInstallation(fixture(), 'old.example', Array(4).fill('a'.repeat(63)).join('.').slice(0, 250)));
});

test('Bash and PowerShell return identical bytes and codes for help and rejected modes', () => {
  const root = fileURLToPath(new URL('../', import.meta.url));
  for (const args of [['--help'], ['--apply'], ['--dry-run', '--dry-run'], ['--books-fqdn', '--bad', '--dry-run']]) {
    const bash = spawnSync('bash', [root + 'lifecycle/plan-installation-domain.sh', ...args]);
    const ps = spawnSync('pwsh', ['-NoProfile', '-File', root + 'lifecycle/plan-installation-domain.ps1', ...args]);
    assert.equal(bash.error, undefined); assert.equal(ps.error, undefined);
    assert.equal(ps.status, bash.status, ps.stderr.toString());
    assert.equal(ps.stdout.toString(), bash.stdout.toString());
    assert.equal(ps.stderr.toString(), bash.stderr.toString());
    assert.equal(bash.status, args[0] === '--help' ? 0 : 64);
  }
});

test('inventory accepts concrete Host spellings and fails on unsupported hostname matchers', () => {
  const routes = match => [{spec: {routes: [{match}]}}];
  assert.deepEqual(installedIngressHosts(routes('Host("argo.master.old.example") || Host(`vault.master.old.example`)')), ['argo.master.old.example', 'vault.master.old.example']);
  assert.deepEqual(installedIngressHosts(routes('Host ("a.old.example", `b.old.example`)')), ['a.old.example', 'b.old.example']);
  assert.deepEqual(installedIngressHosts(routes('PathPrefix("/Host(`ghost.old.example`)") && Host("real.old.example")')), ['real.old.example']);
  assert.throws(() => installedIngressHosts(routes('HostRegexp(`.+.old.example`)')), /incomplete/);
  assert.throws(() => installedIngressHosts(routes('HostSNI(`*.old.example`)')), /incomplete/);
  assert.throws(() => installedIngressHosts(routes('Host(unquoted.old.example)')), /malformed/);
});
