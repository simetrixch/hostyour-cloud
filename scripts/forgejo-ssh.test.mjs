import assert from 'node:assert/strict';
import {execFile, execFileSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, rmSync, writeFileSync} from 'node:fs';
import {createServer} from 'node:net';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import test from 'node:test';
import {promisify} from 'node:util';

// lifecycle/check-forgejo-ssh.sh asks the SSH port an installation announces for Forgejo (on its install
// branch) for an SSH banner. The fixtures stand a branch in a directory origin and a listener on a port
// that is not 23, so the port is read from the branch and no literal passes the case; the planted
// defects are a closed port, a port that speaks something else and a port that stays silent.

const script = resolve('lifecycle/check-forgejo-ssh.sh');
const run = promisify(execFile);
const git = (cwd, ...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...args], {cwd, encoding: 'utf8'});
const root = mkdtempSync(join(tmpdir(), 'forgejo-ssh-'));
test.after(() => rmSync(root, {recursive: true, force: true}));

/** A repository whose origin carries the branch `fqdn`, announcing `port` on 127.0.0.1 (none when port is null). */
function installation(name, fqdn, port) {
  const origin = join(root, `${name}.git`), work = join(root, name);
  git(root, 'init', '--bare', '-q', '-b', 'master', origin);
  // Pushed to, never cloned from: a clone of the still empty origin warns that it is empty.
  git(root, 'init', '-q', '-b', fqdn, work);
  git(work, 'remote', 'add', 'origin', origin);
  mkdirSync(join(work, 'installation/values'), {recursive: true});
  writeFileSync(join(work, 'installation/values/forgejo.yaml'),
    port === null ? 'forgejo: {}\n' : `forgejo:\n  gitea:\n    config:\n      server:\n        SSH_DOMAIN: 127.0.0.1\n        SSH_PORT: ${port}\n`);
  git(work, 'add', '-A');
  git(work, 'commit', '-q', '-m', 'announce');
  git(work, 'push', '-q', 'origin', fqdn);
  return work;
}

const listen = (onConnect) => new Promise(done => {
  const server = createServer(onConnect).listen(0, '127.0.0.1', () => done(server));
});
const closed = async () => { const server = await listen(() => {}); const {port} = server.address(); await new Promise(done => server.close(done)); return port; };
const check = async (cwd, fqdn) => run('bash', [script, fqdn], {cwd}).then(
  ({stdout}) => ({code: 0, stdout, stderr: ''}), error => ({code: error.code, stdout: error.stdout, stderr: error.stderr}));

test('PLANTED INNOCENT: a port that sends an SSH banner is green, and the port is the branch\'s, not 23', async () => {
  const server = await listen(socket => { socket.end('SSH-2.0-Go\r\n'); });
  const {port} = server.address();
  assert.notEqual(port, 23);
  const result = await check(installation('live', 'live.example.invalid', port), 'live.example.invalid');
  server.close();
  assert.deepEqual([result.code, result.stdout], [0, `check-forgejo-ssh: 127.0.0.1:${port} answers SSH-2.0-Go\n`]);
});

test('PLANTED DEFECT: a closed port is red', async () => {
  const port = await closed();
  const result = await check(installation('shut', 'shut.example.invalid', port), 'shut.example.invalid');
  assert.deepEqual([result.code, result.stderr], [1, `check-forgejo-ssh: 127.0.0.1:${port} gave no SSH banner\n`]);
});

test('PLANTED DEFECT: a port that speaks something else, or stays silent, is red', async () => {
  const web = await listen(socket => { socket.end('HTTP/1.1 400 Bad Request\r\n\r\n'); });
  const mute = await listen(() => {});
  const spoke = await check(installation('web', 'web.example.invalid', web.address().port), 'web.example.invalid');
  const silent = await check(installation('mute', 'mute.example.invalid', mute.address().port), 'mute.example.invalid');
  web.close(); mute.close();
  assert.equal(spoke.code, 1);
  assert.equal(silent.code, 1);
});

test('a branch that runs no Forgejo is 66, which status and install-machine read as no row', async () => {
  const work = installation('plain', 'plain.example.invalid', 1);
  git(work, 'rm', '-q', 'installation/values/forgejo.yaml');
  git(work, 'commit', '-q', '-m', 'no forge');
  git(work, 'push', '-q', 'origin', 'plain.example.invalid');
  assert.equal((await check(work, 'plain.example.invalid')).code, 66);
});

test('a branch that announces no port, and a branch that is none, cannot be asked', async () => {
  assert.equal((await check(installation('bare', 'bare.example.invalid', null), 'bare.example.invalid')).code, 67);
  assert.equal((await check(installation('none', 'none.example.invalid', 1), 'missing.example.invalid')).code, 69);
});

test('PLANTED DEFECT: a Git command of a fixture that fails throws, so no case stands on a broken fixture', () => {
  assert.throws(() => git(root, 'clone', '-q', join(root, 'absent.git'), join(root, 'absent')), {status: 128});
});
