import {createServer} from 'node:http';
import {connect} from 'node:net';
import {spawn} from 'node:child_process';
import {createRequire} from 'node:module';
import {mkdirSync, mkdtempSync, writeFileSync, readFileSync, rmSync} from 'node:fs';
import {join} from 'node:path';
import {registryHosts, sanitizedDependencyRoot} from './test-dependency-policy.mjs';
import {redact} from './test-contract.mjs';

export async function fetchPackages(source, roots, directory, authPath) {
  const tools = join(directory, 'tools');
  const {parse, stringify} = createRequire(import.meta.url)(join(tools, 'yaml/dist/index.js'));
  const scratch = mkdtempSync('/tmp/cloud-dependencies-');
  const store = join(directory, 'store');
  mkdirSync(store, {mode: 0o755});
  const configuration = join(scratch, 'npmrc');
  // Accept only the existing ESO reader's two approved lines. Never copy a
  // source npmrc, or route the credential to an unscoped/default registry.
  const auth = readFileSync(authPath, 'utf8');
  if (!/^@digitaplatform:registry=https:\/\/npm\.pkg\.github\.com\/?\n\/\/npm\.pkg\.github\.com\/:_authToken=[A-Za-z0-9_.-]+\n?$/.test(auth)) {
    throw new Error('unexpected scoped package-reader configuration');
  }
  writeFileSync(configuration, auth + '\nregistry=https://registry.npmjs.org/\n', {mode: 0o600});
  const sockets = new Set();
  const proxy = createServer((_, response) => response.writeHead(405).end());
  proxy.on('connect', (request, client, head) => {
    const match = /^([a-z0-9.-]+):443$/.exec(request.url ?? '');
    if (!match || !registryHosts.has(match[1])) {client.end('HTTP/1.1 403 Forbidden\r\n\r\n'); return;}
    const upstream = connect({host: match[1], port: 443});
    for (const socket of [client, upstream]) {
      sockets.add(socket); socket.setTimeout(30000, () => socket.destroy());
      socket.on('close', () => sockets.delete(socket));
      socket.on('error', () => {client.destroy(); upstream.destroy();});
    }
    upstream.on('connect', () => {
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      if (head.length) upstream.write(head);
      client.pipe(upstream); upstream.pipe(client);
    });
  });
  await new Promise((done, reject) => {proxy.once('error', reject); proxy.listen(0, '127.0.0.1', done);});
  try {
    for (let index = 0; index < roots.length; index++) {
      const clean = join(scratch, String(index)); mkdirSync(clean, {mode: 0o700});
      sanitizedDependencyRoot(source, roots[index], clean, parse, stringify);
      await new Promise((done, reject) => {
        const child = spawn(process.execPath, [join(tools, 'pnpm/bin/pnpm.cjs'), 'fetch', '--ignore-scripts', '--ignore-pnpmfile',
          '--store-dir', store, '--config.manage-package-manager-versions=false', '--config.package-manager-strict=false',
          '--config.https-proxy=http://127.0.0.1:' + proxy.address().port], {
          cwd: clean, env: {PATH: '/usr/local/bin:/usr/bin:/bin', HOME: scratch, CI: 'true',
            NPM_CONFIG_USERCONFIG: configuration, NPM_CONFIG_GLOBALCONFIG: '/dev/null'}, stdio: ['ignore', 'pipe', 'pipe']});
        let size = 0; let output = '';
        const timer = setTimeout(() => child.kill('SIGKILL'), 15 * 60 * 1000);
        const collect = chunk => {size += chunk.length; if (size > 4 * 1024 * 1024) child.kill('SIGKILL'); else output += chunk.toString();};
        child.stdout.on('data', collect); child.stderr.on('data', collect);
        child.on('error', error => {clearTimeout(timer); reject(error);});
        child.on('close', code => {clearTimeout(timer); process.stdout.write(redact(output));
          if (code !== 0 || size > 4 * 1024 * 1024) reject(new Error('trusted package fetch did not complete')); else done();});
      });
    }
  } finally {
    for (const socket of sockets) socket.destroy();
    await new Promise(done => proxy.close(done));
    rmSync(scratch, {recursive: true, force: true});
  }
}
