import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, readFile, writeFile, readdir, rm, chmod} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {test} from 'node:test';

const HERE = new URL('./', import.meta.url);
const PLANE = 'fixture-private-plane-update-status', PASSWORD = 'fixture-private-elevation-password';
const declaration = `name: deploy-platform-services
roles: [master]
steps: []
answers:
  - name: fqdn
    kind: text
  - name: stage
    kind: text
  - name: role
    kind: text
  - name: operator_user
    kind: text
  - name: build_plane_fqdn
    kind: text
  - name: plane_api_token
    kind: text
    secret: true
    required: false
  - name: elevation_password
    kind: text
    secret: true
`;

async function fixture(options = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'platform-redeploy-'));
  const calls = [], phases = [];
  let child, stdout = '', stderr = '';
  const server = createServer(async (req, res) => {
    let text = ''; for await (const data of req) text += data;
    const call = JSON.parse(text); calls.push(call);
    const command = call.argv.at(-1);
    const phase = command.match(/--mode (test|dry|run)/)?.[1];
    if (phase) {
      phases.push(phase);
      if (options.cancel === phase) {
        child.kill('SIGTERM');
        return;
      }
      res.writeHead(options.fail === phase ? 500 : 200);
      res.end(options.leak ? PLANE : 'innocent non-secret program output\n');
    } else if (command.startsWith('cat ')) {
      res.end(options.oldProgram ? declaration.replace('plane_api_token', 'unrelated_token') : declaration);
    } else {
      res.writeHead(options.birth ? 500 : 200); res.end('installed master\n');
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  for (const file of ['redeploy-platform-services.sh', 'driver.sh', 'require-owner-only.sh']) {
    await writeFile(join(directory, file), await readFile(new URL(file, HERE)));
  }
  await writeFile(join(directory, 'ssh'), `#!/usr/bin/env node
let input='';if(!process.argv.includes('-n')) for await(const chunk of process.stdin) input+=chunk;
const r=await fetch('http://127.0.0.1:${port}',{method:'POST',body:JSON.stringify({argv:process.argv.slice(2),input})});
process.stdout.write(await r.text());process.exit(r.status===200?0:1);
`, {mode: 0o700});
  const file = join(directory, 'config.fixture.env');
  let config = `FQDN='master.fixture.invalid'
OPERATOR_USER='master'
STAGE='prod'
ROLE='master'
BUILD_PLANE_FQDN='master.fixture.invalid'
ACME_SERVER='https://dv.acme-v02.api.pki.goog/directory'
ELEVATION_PASSWORD='${PASSWORD}'
UNDECLARED_TOKEN='fixture-excluded-credential'
`;
  if (!options.missing) config += `PLANE_API_TOKEN='${options.empty ? '' : PLANE}'\n`;
  if (options.invalid) config += 'echo ' + PLANE + '\n';
  await writeFile(file, config, {mode: 0o600});
  if (options.openMode) await chmod(file, 0o644);
  const run = () => new Promise((resolve, reject) => {
    child = spawn('bash', [join(directory, 'redeploy-platform-services.sh'), file], {
      cwd: directory, env: {...process.env, PATH: directory + ':' + process.env.PATH},
    });
    child.stdin.end();
    child.stdout.on('data', d => stdout += d); child.stderr.on('data', d => stderr += d);
    child.on('error', reject); child.on('close', (code, signal) => resolve({code, signal, stdout, stderr}));
  });
  const privateRecords = async () => {
    for (const secret of [PLANE, PASSWORD, 'fixture-excluded-credential']) {
      assert.ok(!stdout.includes(secret) && !stderr.includes(secret), 'output holds a credential');
      for (const call of calls) assert.ok(!call.argv.join(' ').includes(secret), 'arguments hold a credential');
      for (const name of await readdir(directory)) {
        if (name === 'config.fixture.env') continue;
        assert.ok(!(await readFile(join(directory, name), 'utf8')).includes(secret), name + ' holds a credential');
      }
    }
  };
  const clean = async () => {server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, {recursive: true, force: true});};
  return {run, calls, phases, privateRecords, clean};
}

test('the installed master receives only declared answers and the password envelope over stdin', async () => {
  const f = await fixture();
  try {
    const r = await f.run(); assert.equal(r.code, 0, r.stderr);
    assert.deepEqual(f.phases, ['test', 'dry', 'run']);
    for (const call of f.calls.filter(c => c.input)) {
      assert.match(call.argv.at(-1), /deploy-platform-services/);
      assert.match(call.argv.at(-1), /--answers - /);
      const envelope = JSON.parse(call.input);
      assert.equal(envelope.elevation_password, PASSWORD);
      assert.equal(envelope.answers.plane_api_token, PLANE);
      assert.equal(envelope.answers.elevation_password, undefined);
      assert.equal(envelope.answers.undeclared_token, undefined);
      assert.equal(envelope.answers.acme_server, undefined);
    }
    assert.equal(f.calls.filter(c => c.input).length, 3);
    await f.privateRecords();
  } finally {await f.clean();}
});

test('missing or empty PLANE_API_TOKEN and an invalid or readable config stop before SSH', async () => {
  for (const options of [{missing: true}, {empty: true}, {invalid: true}, {openMode: true}]) {
    const f = await fixture(options);
    try {
      const r = await f.run(); assert.notEqual(r.code, 0);
      if (options.missing || options.empty) assert.match(r.stderr, /PLANE_API_TOKEN/);
      assert.equal(f.calls.length, 0);
      await f.privateRecords();
    } finally {await f.clean();}
  }
});

test('a birth or stale installed program starts no mode', async () => {
  for (const options of [{birth: true}, {oldProgram: true}]) {
    const f = await fixture(options);
    try {
      assert.notEqual((await f.run()).code, 0);
      assert.deepEqual(f.phases, []);
      await f.privateRecords();
    } finally {await f.clean();}
  }
});

test('failure and cancellation leave no answer/config copies and stop subsequent modes', async () => {
  for (const options of [{fail: 'dry'}, {cancel: 'dry'}]) {
    const f = await fixture(options);
    try {
      assert.notEqual((await f.run()).code, 0);
      assert.deepEqual(f.phases, ['test', 'dry']);
      await f.privateRecords();
    } finally {await f.clean();}
  }
});

test('the records check catches a planted output leak beside an innocent run', async () => {
  const innocent = await fixture();
  try {assert.equal((await innocent.run()).code, 0); await innocent.privateRecords();}
  finally {await innocent.clean();}
  const leaked = await fixture({leak: true});
  try {await leaked.run(); await assert.rejects(leaked.privateRecords(), /output holds a credential/);}
  finally {await leaked.clean();}
});
