import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readdirSync, readFileSync} from 'node:fs';
import test from 'node:test';
import {isDeepStrictEqual} from 'node:util';

// The account `platform-sign-in` and the group `platform-readers` once served a sign-in proof of Argo CD and Headlamp.
// Those are the owner's own consoles and get no test account and no proof run, so both are gone. An entry that a
// blueprint stops declaring does not delete its object in Authentik, so clusters/bootstrap/idp/blueprints/
// 21-platform-test-accounts.yaml stays and declares both absent; the bindings of the group fall with it. This file holds
// that removal, that no other blueprint declares either again, that no application of the identity provider admits
// the group (scripts/plane-test-accounts.test.mjs holds that), and that Argo CD's own admission is what it was
// before the account existed: `admins` administrate it and anybody else gets the read-only default.

const blueprintDirectory = 'clusters/bootstrap/idp/blueprints';
const REMOVAL_BLUEPRINT = '21-platform-test-accounts.yaml';
const PLANE_BLUEPRINT = '20-plane-test-accounts.yaml';
const blueprintTexts = Object.fromEntries(readdirSync(blueprintDirectory).filter(name => name.endsWith('.yaml')).sort()
  .map(name => [name, readFileSync(`${blueprintDirectory}/${name}`, 'utf8')]));
const argocdText = readFileSync('clusters/bootstrap/argocd/values.tpl', 'utf8');
const idpValues = JSON.parse(execFileSync('yq', ['-o=json', '.', 'clusters/bootstrap/idp/values.yaml'], {encoding: 'utf8'}));

const GROUP = 'platform-readers';
const ACCOUNT = 'platform-sign-in';
const REMOVALS = [
  {model: 'authentik_core.user', identifiers: {username: ACCOUNT}, state: 'absent'},
  {model: 'authentik_core.group', identifiers: {name: GROUP}, state: 'absent'},
];

const parse = text => JSON.parse(execFileSync('yq', ['-o=json', '.', '-'], {input: text, encoding: 'utf8'}));

/** The lines of one key of Argo CD's `rbac:` block, which values.tpl holds as template text and not as YAML. */
function rbacLines(text, key) {
  const lines = text.split('\n');
  const start = lines.findIndex(line => new RegExp(`^\\s+${key.replace('.', '\\.')}:`).test(line));
  if (start < 0) return null;
  const indent = lines[start].match(/^\s*/)[0].length;
  const block = [lines[start].replace(/^\s+[^:]+:\s*\|?\s*/, '')];
  for (const line of lines.slice(start + 1)) {
    if (line.trim() !== '' && line.match(/^\s*/)[0].length <= indent) break;
    block.push(line);
  }
  return block.map(line => line.trim()).filter(line => line !== '' && !line.startsWith('#'));
}

/** Every way the blueprint of the removals is not exactly the removal of the account and of the group, named. */
function removalFindings(text) {
  const found = [];
  const blueprint = parse(text);
  if (blueprint.metadata?.labels?.['blueprints.goauthentik.io/instantiate'] !== 'true') found.push('the blueprint is not instantiated, so Authentik never applies its removals');
  const entries = (blueprint.entries ?? []).map(({id, ...entry}) => entry);
  for (const removal of REMOVALS) {
    if (!entries.some(entry => isDeepStrictEqual(entry, removal))) found.push(`the blueprint does not declare ${JSON.stringify(removal.identifiers)} of ${removal.model} absent with no attrs`);
  }
  for (const entry of entries) {
    if (!REMOVALS.some(removal => isDeepStrictEqual(entry, removal))) found.push(`the blueprint holds ${JSON.stringify(entry)}, which is no removal of the account or the group`);
  }
  if (entries.length !== REMOVALS.length) found.push(`the blueprint holds ${entries.length} entries, not ${REMOVALS.length}`);
  return found;
}

/** Every blueprint that declares the group or an account other than the two of Plane's sign-in proof present, named. */
function strayFindings(texts) {
  const found = [];
  for (const [file, text] of Object.entries(texts)) {
    for (const entry of parse(text).entries ?? []) {
      const state = entry.state ?? 'present';
      if (entry.model === 'authentik_core.group' && (entry.identifiers?.name === GROUP || entry.attrs?.name === GROUP) && state !== 'absent') found.push(`${file} declares the group ${GROUP} ${state}`);
      if (entry.model === 'authentik_core.user' && state !== 'absent' && file !== PLANE_BLUEPRINT) found.push(`${file} declares the account ${entry.identifiers?.username} ${state}, and only ${PLANE_BLUEPRINT} declares accounts`);
    }
  }
  return found;
}

/** Every way the provider or Argo CD still knows the account or the group, or the owner's admission changed, named. */
function admissionFindings(values, argocd) {
  const found = [];
  if (values.global.podAnnotations['platform/test-accounts'].split(' ').includes(ACCOUNT)) found.push(`platform/test-accounts still lists ${ACCOUNT}, an account that is gone`);
  const policy = rbacLines(argocd, 'policy.csv');
  if (policy === null || !policy.includes('g, admins, role:admin')) found.push('the policy.csv of Argo CD was not read or holds no admins line, so the owner is no administrator of it');
  for (const line of policy ?? []) {
    if (line.includes(GROUP) || line.includes(ACCOUNT)) found.push(`policy.csv of Argo CD names ${GROUP} or ${ACCOUNT} in "${line}"`);
  }
  const fallback = rbacLines(argocd, 'policy.default');
  if (!isDeepStrictEqual(fallback, ['role:readonly'])) found.push(`policy.default of Argo CD is ${fallback}, not the read-only role it has always been`);
  return found;
}

test('the blueprint declares the account platform-sign-in and the group platform-readers absent, with no attrs, and nothing else', () => {
  assert.deepEqual(removalFindings(blueprintTexts[REMOVAL_BLUEPRINT]), []);
});

test('PLANTED DEFECT: an account or group that is not absent, an attr on a removal, a missing or extra entry, or a blueprint that is not instantiated is found', () => {
  const planted = {
    'the account without state absent': text => text.replace(/(model: authentik_core\.user\n)\s+state: absent\n/, '$1'),
    'the account created': text => text.replace(/(model: authentik_core\.user\n\s+)state: absent/, '$1state: created'),
    'the group created': text => text.replace(/(model: authentik_core\.group\n\s+)state: absent/, '$1state: created'),
    'the group without state absent': text => text.replace(/(model: authentik_core\.group\n)\s+state: absent\n/, '$1'),
    'a password on the account': text => text.replace(/(username: platform-sign-in\n)/, '$1    attrs:\n      password: !Env IDP_PLATFORM_TEST_ACCOUNT_PASSWORD\n'),
    'groups on the account': text => text.replace(/(username: platform-sign-in\n)/, '$1    attrs:\n      groups:\n        - !KeyOf platform-readers-group\n'),
    'the group dropped': text => text.replace(/ {2}- id: platform-readers-group[\s\S]*$/, ''),
    'the account dropped': text => text.replace(/ {2}- id: platform-sign-in-account\n[\s\S]*?(?= {2}- id: platform-readers-group)/, ''),
    'a second account removed too': text => `${text}  - id: planted-account\n    model: authentik_core.user\n    state: absent\n    identifiers:\n      username: planted\n`,
    'the account declared twice': text => `${text}  - id: planted-copy\n    model: authentik_core.user\n    state: absent\n    identifiers:\n      username: platform-sign-in\n`,
    'the instantiate label dropped': text => text.replace(/ {4}blueprints\.goauthentik\.io\/instantiate: "true"\n/, ''),
  };
  for (const [name, plant] of Object.entries(planted)) {
    const text = plant(blueprintTexts[REMOVAL_BLUEPRINT]);
    assert.notEqual(text, blueprintTexts[REMOVAL_BLUEPRINT], `${name}: the plant matched nothing`);
    assert.notDeepEqual(removalFindings(text), [], name);
  }
});

test('PLANTED INNOCENT: a comment, a comment after the version and the removals in the other order change nothing the rules hold', () => {
  const text = blueprintTexts[REMOVAL_BLUEPRINT];
  assert.deepEqual(removalFindings(`# planted comment naming platform-readers and password: !Env\n${text}`), []);
  assert.deepEqual(removalFindings(text.replace('version: 1', 'version: 1 # planted')), []);
  const [head, ...entries] = text.split(/(?<=\n)(?= {2}- id: )/);
  assert.equal(entries.length, REMOVALS.length);
  assert.deepEqual(removalFindings([head, ...entries.reverse()].join('')), []);
});

const readersGroup = state => `  - id: planted-group\n    model: authentik_core.group\n${state ? `    state: ${state}\n` : ''}    identifiers:\n      name: platform-readers\n    attrs:\n      name: platform-readers\n`;

test('no other blueprint declares the group platform-readers present, and no blueprint but the Plane one declares an account present', () => {
  assert.deepEqual(strayFindings(blueprintTexts), []);
});

test('PLANTED DEFECT: the group created or present in another blueprint, or an account declared present in another blueprint, is found', () => {
  const planted = {
    'the group created by 99-headlamp.yaml': ['99-headlamp.yaml', text => text + readersGroup('created')],
    'the group created by 99-proxy-headlamp.yaml': ['99-proxy-headlamp.yaml', text => text + readersGroup('created')],
    'the group present in 99-argocd.yaml': ['99-argocd.yaml', text => text + readersGroup('')],
    'an account declared present by 99-grafana.yaml': ['99-grafana.yaml', text => `${text}  - id: planted-account\n    model: authentik_core.user\n    identifiers:\n      username: planted\n    attrs:\n      username: planted\n`],
    'the account created by 99-vault.yaml': ['99-vault.yaml', text => `${text}  - id: planted-account\n    model: authentik_core.user\n    state: created\n    identifiers:\n      username: platform-sign-in\n`],
  };
  for (const [name, [file, plant]] of Object.entries(planted)) {
    const text = plant(blueprintTexts[file]);
    assert.notEqual(text, blueprintTexts[file], `${name}: the plant matched nothing`);
    assert.notDeepEqual(strayFindings({...blueprintTexts, [file]: text}), [], name);
  }
});

test('PLANTED INNOCENT: a comment naming the group, and a copy of the absent group entry under another id, change nothing the rules hold', () => {
  assert.deepEqual(strayFindings({...blueprintTexts, '99-argocd.yaml': `# planted comment naming platform-readers\n${blueprintTexts['99-argocd.yaml']}`}), []);
  assert.deepEqual(strayFindings({...blueprintTexts, '99-argocd.yaml': blueprintTexts['99-argocd.yaml'] + readersGroup('absent')}), []);
});

test('the provider is not told to restart onto the account, and Argo CD gives the owner the administrator role and everybody else the read-only default', () => {
  assert.deepEqual(admissionFindings(idpValues, argocdText), []);
});

test('PLANTED DEFECT: the account in the annotation, a role for the group or the account, or a changed default or owner role of Argo CD is found', () => {
  const planted = {
    'the account in the annotation': ['values', values => { values.global.podAnnotations['platform/test-accounts'] += ' platform-sign-in'; }],
    'the group an administrator of Argo CD': ['argocd', text => text.replace('g, admins, role:admin\n', 'g, admins, role:admin\n      g, platform-readers, role:admin\n')],
    'the account an administrator of Argo CD': ['argocd', text => text.replace('g, admins, role:admin\n', 'g, admins, role:admin\n      g, platform-sign-in, role:admin\n')],
    'a policy for the group': ['argocd', text => text.replace('g, admins, role:admin\n', 'g, admins, role:admin\n      p, platform-readers, applications, sync, */*, allow\n')],
    'an administrator by default': ['argocd', text => text.replace(/^(\s+)policy\.default: role:readonly$/m, '$1policy.default: role:admin')],
    'the owner\'s group without its role': ['argocd', text => text.replace('g, admins, role:admin\n', '')],
    'no policy.csv to read': ['argocd', text => text.replace('policy.csv: |', 'policy.csvs: |')],
  };
  for (const [name, [kind, plant]] of Object.entries(planted)) {
    const values = structuredClone(idpValues);
    let argocd = argocdText;
    if (kind === 'values') plant(values);
    else argocd = plant(argocdText);
    assert.notEqual(JSON.stringify([values, argocd]), JSON.stringify([idpValues, argocdText]), `${name}: the plant matched nothing`);
    assert.notDeepEqual(admissionFindings(values, argocd), [], name);
  }
});

test('PLANTED INNOCENT: a comment inside policy.csv naming the group, and the other accounts in the annotation, change nothing the rules hold', () => {
  const commented = argocdText.replace('g, admins, role:admin\n', 'g, admins, role:admin\n      # platform-readers has no line here\n');
  assert.notEqual(commented, argocdText, 'the plant matched');
  assert.deepEqual(admissionFindings(idpValues, commented), []);
  const other = structuredClone(idpValues);
  other.global.podAnnotations['platform/test-accounts'] += ' planted-account';
  assert.deepEqual(admissionFindings(other, argocdText), []);
});
