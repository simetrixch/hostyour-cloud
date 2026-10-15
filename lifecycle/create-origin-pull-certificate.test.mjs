import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {chmodSync, copyFileSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';

// create-origin-pull-certificate.sh writes the three origin pull answers into a config. What the
// origins accept is decided by an X.509 chain check against the CA answer, which openssl verify makes
// the way the ingress controller's TLS stack makes it: a certificate passes when it chains to one CA
// of the bundle and is in its validity period.

const HERE = fileURLToPath(new URL('.', import.meta.url));
const ACT = 'create-origin-pull-certificate.sh';
const DNS_TOKEN = 'dns-token-sentinel-7f3a';

/** A folder holding the act (or a planted copy of it), its guard, a config and a temporary folder of its own. */
function fixture(text = readFileSync(join(HERE, ACT), 'utf8')) {
  const root = mkdtempSync(join(tmpdir(), 'origin-pull-'));
  writeFileSync(join(root, ACT), text);
  copyFileSync(join(HERE, 'require-owner-only.sh'), join(root, 'require-owner-only.sh'));
  writeFileSync(join(root, 'config.env'), `FQDN='master.example.invalid'\nCLOUDFLARE_DNS_API_TOKEN='${DNS_TOKEN}'\n`);
  chmodSync(join(root, 'config.env'), 0o600);
  execFileSync('mkdir', [join(root, 'tmp')]);
  return root;
}
const run = root => spawnSync('bash', [join(root, ACT), join(root, 'config.env')], {encoding: 'utf8', env: {...process.env, TMPDIR: join(root, 'tmp')}});
const answer = (root, key) => {
  const line = readFileSync(join(root, 'config.env'), 'utf8').split('\n').find(l => l.startsWith(`${key}='`));
  return line?.slice(key.length + 2, -1).replaceAll('\\n', '\n');
};
const certificates = pem => pem.match(/-----BEGIN CERTIFICATE-----[^-]+-----END CERTIFICATE-----\n/g) ?? [];
/** Whether openssl accepts [client] against the CA bundle [ca], at [days] from now. */
function passes(root, ca, client, days = 0) {
  writeFileSync(join(root, 'ca.pem'), ca);
  writeFileSync(join(root, 'client.pem'), client);
  const at = ['-attime', String(Math.floor(Date.now() / 1000) + days * 86400)];
  return spawnSync('openssl', ['verify', '-purpose', 'sslclient', ...at, '-CAfile', join(root, 'ca.pem'), join(root, 'client.pem')], {encoding: 'utf8'}).status === 0;
}
const publicKey = (args, input) => execFileSync('openssl', args, {input, encoding: 'utf8'});

/** Three runs of the act in [root], and every way their answers fail the origins, named. */
function findings(root) {
  const found = [];
  const clients = [];
  for (const round of [1, 2, 3]) {
    const result = run(root);
    if (result.status !== 0) { found.push(`run ${round} ended ${result.status}: ${result.stderr}`); return found; }
    const ca = answer(root, 'CLOUDFLARE_ORIGIN_PULL_CA') ?? '';
    const client = answer(root, 'CLOUDFLARE_ORIGIN_PULL_CERTIFICATE') ?? '';
    const key = answer(root, 'CLOUDFLARE_ORIGIN_PULL_PRIVATE_KEY') ?? '';
    clients.push(client);
    const config = readFileSync(join(root, 'config.env'), 'utf8');
    if (certificates(ca).length !== (round === 1 ? 1 : 2)) found.push(`run ${round}: the CA answer holds ${certificates(ca).length} certificates`);
    if (!passes(root, ca, client)) found.push(`run ${round}: the new client certificate does not pass`);
    if (round > 1 && !passes(root, ca, clients[round - 2])) found.push(`run ${round}: the client certificate before it does not pass while Cloudflare moves`);
    if (round === 3 && passes(root, ca, clients[0])) found.push('run 3: the first client certificate still passes after its CA was dropped');
    if (passes(root, ca, client, 800)) found.push(`run ${round}: the client certificate passes past its end`);
    if (publicKey(['x509', '-noout', '-pubkey'], client) !== publicKey(['pkey', '-pubout'], key)) found.push(`run ${round}: the key is not the certificate's`);
    if ((config.match(/PRIVATE KEY-----/g) ?? []).length !== 2) found.push(`run ${round}: the config holds another private key than the client's`);
    if (!config.includes(`CLOUDFLARE_DNS_API_TOKEN='${DNS_TOKEN}'`)) found.push(`run ${round}: the DNS token line changed`);
    if (/PRIVATE KEY|BEGIN CERTIFICATE/.test(result.stdout + result.stderr)) found.push(`run ${round}: a PEM was printed`);
    if (readdirSync(join(root, 'tmp')).length) found.push(`run ${round}: its temporary folder stands`);
  }
  const stranger = mkdtempSync(join(tmpdir(), 'origin-pull-stranger-'));
  try {
    execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(stranger, 'k'), '-out', join(stranger, 'c'), '-days', '30', '-subj', '/CN=stranger'], {stdio: 'ignore'});
    if (passes(root, answer(root, 'CLOUDFLARE_ORIGIN_PULL_CA'), readFileSync(join(stranger, 'c'), 'utf8'))) found.push('a certificate of another CA passes');
  } finally { rmSync(stranger, {recursive: true, force: true}); }
  return found;
}

test('three runs make a client certificate the CA answer admits, keep the one before during a rotation, drop the one before that, and keep no CA key', () => {
  const root = fixture();
  try { assert.deepEqual(findings(root), []); } finally { rmSync(root, {recursive: true, force: true}); }
});

test('a config others can read is refused before anything is made, and stays as it was', () => {
  const root = fixture();
  try {
    chmodSync(join(root, 'config.env'), 0o644);
    const before = readFileSync(join(root, 'config.env'), 'utf8');
    const result = run(root);
    assert.equal(result.status, 65);
    assert.match(result.stderr, /is mode 644, and the private key of the origin pull certificate would land in it\. Make it owner-only with: chmod 600 /);
    assert.equal(readFileSync(join(root, 'config.env'), 'utf8'), before);
  } finally { rmSync(root, {recursive: true, force: true}); }
});

test('PLANTED DEFECT: an act that drops the standing CA, keeps the CA key or leaves its folder is caught', () => {
  const act = readFileSync(join(HERE, ACT), 'utf8');
  const planted = {
    'the standing CA is dropped': act.replace('[ -z "$KEPT" ] || CA_LINE="$KEPT$CA_LINE"', ': "$KEPT"'),
    'the CA key is written': act.replace('write_config_value CLOUDFLARE_ORIGIN_PULL_CA "$CA_LINE"', 'write_config_value CLOUDFLARE_ORIGIN_PULL_CA "$CA_LINE$(one_line "$WORK/ca.key")"'),
    'the temporary folder stands': act.replace(`trap 'rm -rf "$WORK"' EXIT`, ':'),
    'the client certificate outlives its check': act.replace('DAYS=730', 'DAYS=900'),
  };
  for (const [name, text] of Object.entries(planted)) {
    assert.notEqual(text, act, name);
    const root = fixture(text);
    try { assert.notDeepEqual(findings(root), [], name); } finally { rmSync(root, {recursive: true, force: true}); }
  }
});
