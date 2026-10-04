import {readFileSync} from 'node:fs';
import {request} from 'node:https';
import {sign} from 'node:crypto';
import {AsyncLocalStorage} from 'node:async_hooks';

const deadlines = new AsyncLocalStorage();
export function withRequestDeadline(milliseconds, action) {
  return deadlines.run(Math.min(deadlines.getStore() ?? Infinity, Date.now() + milliseconds), action);
}

const keyDirectory = '/reporter-key';
let installationToken;
let tokenExpiresAt = 0;

function jsonRequest(url, options = {}, body) {
  const milliseconds = Math.min(15000, (deadlines.getStore() ?? Infinity) - Date.now());
  if (milliseconds <= 0) throw new Error('reconciliation deadline exceeded');
  return new Promise((finish, reject) => {
    const data = body === undefined ? undefined : JSON.stringify(body);
    const call = request(url, {...options, timeout: milliseconds, headers: {
      ...options.headers, ...(data ? {'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data)} : {}),
    }}, response => {
      const chunks = [];
      let length = 0;
      response.on('data', chunk => {
        length += chunk.length;
        if (length > 8 * 1024 * 1024) call.destroy(new Error('API response exceeded limit'));
        else chunks.push(chunk);
      });
      response.on('error', reject);
      response.on('end', () => {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          reject(new Error('API returned HTTP ' + response.statusCode)); return;
        }
        try {finish(response.statusCode === 204 ? undefined : JSON.parse(Buffer.concat(chunks).toString()));}
        catch {reject(new Error('invalid API JSON'));}
      });
    });
    const timer = setTimeout(() => call.destroy(new Error('API request deadline exceeded')), milliseconds);
    call.on('close', () => clearTimeout(timer));
    call.on('timeout', () => call.destroy(new Error('API request timed out')));
    call.on('error', reject);
    if (data) call.write(data);
    call.end();
  });
}

export function kubernetes(path, method = 'GET', body) {
  if (!path.startsWith('/apis/tekton.dev/v1/namespaces/') && !path.startsWith('/api/v1/namespaces/')) {
    throw new Error('unmanaged Kubernetes API path');
  }
  const directory = '/var/run/secrets/kubernetes.io/serviceaccount';
  return jsonRequest('https://' + process.env.KUBERNETES_SERVICE_HOST + ':' + process.env.KUBERNETES_SERVICE_PORT + path,
    {method, ca: readFileSync(directory + '/ca.crt'), headers: {
      Authorization: 'Bearer ' + readFileSync(directory + '/token', 'utf8').trim(),
    }}, body);
}

async function githubToken() {
  if (installationToken && Date.now() < tokenExpiresAt - 60000) return installationToken;
  const appId = readFileSync(keyDirectory + '/app-id', 'utf8').trim();
  const installationId = readFileSync(keyDirectory + '/installation-id', 'utf8').trim();
  if (appId !== process.env.REPORTER_APP_ID || installationId !== process.env.REPORTER_INSTALLATION_ID) {
    throw new Error('reporter App identity does not match configuration');
  }
  const now = Math.floor(Date.now() / 1000);
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const unsigned = encode({alg: 'RS256', typ: 'JWT'}) + '.' + encode({iat: now - 60, exp: now + 540, iss: appId});
  const jwt = unsigned + '.' + sign('RSA-SHA256', Buffer.from(unsigned), readFileSync(keyDirectory + '/private-key')).toString('base64url');
  const reply = await jsonRequest('https://api.github.com/app/installations/' + installationId + '/access_tokens',
    {method: 'POST', headers: {'User-Agent': 'digita-tekton-reporter', Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28', Authorization: 'Bearer ' + jwt}},
    {permissions: {checks: 'write', issues: 'write', metadata: 'read'}});
  if (typeof reply.token !== 'string' || !Number.isFinite(Date.parse(reply.expires_at)) ||
      Object.keys(reply.permissions ?? {}).sort().join() !== 'checks,issues,metadata' ||
      reply.permissions.checks !== 'write' || reply.permissions.issues !== 'write' || reply.permissions.metadata !== 'read') {
    throw new Error('invalid installation token identity or permissions');
  }
  installationToken = reply.token;
  tokenExpiresAt = Date.parse(reply.expires_at);
  return installationToken;
}

export async function validateReporterIdentity() {await githubToken();}

export async function github(path, method = 'GET', body) {
  if (!/^\/repos\/digitaplatform\/[a-z0-9-]+\/(?:commits\/|check-runs|issues\/)/.test(path)) {
    throw new Error('unmanaged GitHub API path');
  }
  return jsonRequest('https://api.github.com' + path, {method, headers: {
    Authorization: 'Bearer ' + await githubToken(), 'User-Agent': 'digita-tekton-reporter',
    Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28',
  }}, body);
}
