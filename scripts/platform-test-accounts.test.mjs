import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import test from 'node:test';

// The account of the Argo CD and Headlamp sign-in proofs (digita-testkit cases/argocd-sign-in.spec.ts and
// cases/headlamp-sign-in.spec.ts). It is declared here and made by the identity provider with the password of
// its own Vault value, and it is a member of the group platform-readers alone: a group that grants no
// administrator right in Authentik, and that Argo CD maps to no role, so its members get the read-only
// default of Argo CD and, on the cluster, the role `view`. Which applications admit the group is held by
// scripts/plane-test-accounts.test.mjs; this file holds what is about the account, the group and Argo CD's
// own admission.

const blueprintText = readFileSync('clusters/bootstrap/idp/blueprints/21-platform-test-accounts.yaml', 'utf8');
const argocdText = readFileSync('clusters/bootstrap/argocd/values.tpl', 'utf8');
const idpValues = JSON.parse(execFileSync('yq', ['-o=json', '.', 'clusters/bootstrap/idp/values.yaml'], {encoding: 'utf8'}));

const GROUP = 'platform-readers';
const ACCOUNT = {username: 'platform-sign-in', email: 'simplidigita.ai+platform-sign-in@gmail.com', password: 'IDP_PLATFORM_TEST_ACCOUNT_PASSWORD'};

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

/** Every way the blueprint or Argo CD's admission breaks the rules above, named. */
function findings(text, values, argocd) {
  const found = [];
  const blueprint = JSON.parse(execFileSync('yq', ['-o=json', '.', '-'], {input: text, encoding: 'utf8'}));
  const tag = path => execFileSync('yq', [`${path} | tag`, '-'], {input: text, encoding: 'utf8'}).trim();
  const groups = blueprint.entries.filter(e => e.model === 'authentik_core.group');
  if (groups.length !== 1 || groups[0].identifiers.name !== GROUP) return [...found, `the groups are ${groups.map(g => g.identifiers.name)}, not ${GROUP} alone`];
  const [group] = groups;
  if (group.state !== 'created') found.push(`the group ${GROUP} is ${group.state ?? 'present'}, so a reconcile would wipe the members the sign-in adds`);
  if (group.attrs?.is_superuser) found.push(`the group ${GROUP} makes its members superusers`);
  if (Object.keys(group.attrs ?? {}).some(key => !['name'].includes(key))) found.push(`the group ${GROUP} carries attributes beyond its name: ${Object.keys(group.attrs)}`);
  if (group.id === undefined) found.push(`the group ${GROUP} has no id, so no account can refer to it`);
  const users = blueprint.entries.filter(e => e.model === 'authentik_core.user');
  if (JSON.stringify(users.map(u => u.identifiers.username)) !== JSON.stringify([ACCOUNT.username])) return [...found, `the accounts are ${users.map(u => u.identifiers.username)}, not ${ACCOUNT.username} alone`];
  const [user] = users;
  const at = blueprint.entries.indexOf(user);
  const where = `the account ${ACCOUNT.username}`;
  if (user.attrs.email !== ACCOUNT.email) found.push(`${where} has the address ${user.attrs.email}`);
  if (user.attrs.is_active !== true) found.push(`${where} is not active`);
  if (user.attrs.password !== ACCOUNT.password || tag(`.entries[${at}].attrs.password`) !== '!Env') found.push(`${where} does not take its password from !Env ${ACCOUNT.password}`);
  if (JSON.stringify(user.attrs.groups) !== JSON.stringify([group.id]) || tag(`.entries[${at}].attrs.groups[0]`) !== '!KeyOf') found.push(`${where} is in other groups than ${GROUP}`);
  if (user.attrs.is_superuser || user.attrs.attributes?.['goauthentik.io/user/superuser']) found.push(`${where} is a superuser`);
  if (user.attrs.type !== undefined && user.attrs.type !== 'internal') found.push(`${where} is of the type ${user.attrs.type}`);
  if (!values.global.podAnnotations['platform/test-accounts'].split(' ').includes(ACCOUNT.username)) found.push(`platform/test-accounts does not list ${ACCOUNT.username}, so the provider never restarts onto the new password`);
  // Argo CD's admission: no line of policy.csv names the group or the account, and the default role is the read-only one.
  const policy = rbacLines(argocd, 'policy.csv');
  if (policy === null || !policy.includes('g, admins, role:admin')) found.push('the policy.csv of Argo CD was not read: it holds no admins line');
  for (const line of policy ?? []) {
    if (line.includes(GROUP) || line.includes(ACCOUNT.username)) found.push(`policy.csv of Argo CD names ${GROUP} or ${ACCOUNT.username} in "${line}"`);
  }
  const fallback = rbacLines(argocd, 'policy.default');
  if (JSON.stringify(fallback) !== JSON.stringify(['role:readonly'])) found.push(`policy.default of Argo CD is ${fallback}, so a member of ${GROUP}, whom no policy line names, gets more than the read-only role`);
  return found;
}

test('the blueprint declares the platform account in the group platform-readers alone with a !Env password, and Argo CD gives that group no role of its own', () => {
  assert.deepEqual(findings(blueprintText, idpValues, argocdText), []);
});

test('PLANTED DEFECT: an administrator group, a second group, a literal password, a superuser, another address, a re-asserted group or an Argo CD role for the group is found', () => {
  const planted = {
    'a member of admins': ['blueprint', text => text.replace(/groups:\n(\s+)- !KeyOf platform-readers-group/, 'groups:\n$1- !KeyOf platform-readers-group\n$1- !Find [authentik_core.group, [name, admins]]')],
    'a member of plane-users beside': ['blueprint', text => text.replace(/groups:\n(\s+)- !KeyOf platform-readers-group/, 'groups:\n$1- !KeyOf platform-readers-group\n$1- !Find [authentik_core.group, [name, plane-users]]')],
    'a literal password': ['blueprint', text => text.replace('!Env IDP_PLATFORM_TEST_ACCOUNT_PASSWORD', 'hunter2-hunter2')],
    'the password of the Plane account': ['blueprint', text => text.replace('!Env IDP_PLATFORM_TEST_ACCOUNT_PASSWORD', '!Env IDP_PLANE_TEST_ACCOUNT_PASSWORD')],
    'a superuser': ['blueprint', text => text.replace('is_active: true', 'is_active: true\n      is_superuser: true')],
    'a group of superusers': ['blueprint', text => text.replace(/(id: platform-readers-group[\s\S]*?attrs:\n\s+name: platform-readers)/, '$1\n      is_superuser: true')],
    'a group re-asserted at every reconcile': ['blueprint', text => text.replace('\n    state: created\n', '\n    state: present\n')],
    'a second account': ['blueprint', text => `${text}  - id: planted-account\n    model: authentik_core.user\n    identifiers:\n      username: planted\n    attrs:\n      username: planted\n`],
    'another address': ['blueprint', text => text.replace('simplidigita.ai+platform-sign-in@gmail.com', 'owner@example.com')],
    'the bare test mailbox': ['blueprint', text => text.replace('simplidigita.ai+platform-sign-in@gmail.com', 'simplidigita.ai@gmail.com')],
    'the group an administrator of Argo CD': ['argocd', text => text.replace('g, admins, role:admin\n', 'g, admins, role:admin\n      g, platform-readers, role:admin\n')],
    'the account an administrator of Argo CD': ['argocd', text => text.replace('g, admins, role:admin\n', 'g, admins, role:admin\n      g, platform-sign-in, role:admin\n')],
    'a policy for the group': ['argocd', text => text.replace('g, admins, role:admin\n', 'g, admins, role:admin\n      p, platform-readers, applications, sync, */*, allow\n')],
    'an administrator by default': ['argocd', text => text.replace(/^(\s+)policy\.default: role:readonly$/m, '$1policy.default: role:admin')],
    'no policy.csv to read': ['argocd', text => text.replace('policy.csv: |', 'policy.csvs: |')],
  };
  for (const [name, [kind, plant]] of Object.entries(planted)) {
    const source = kind === 'blueprint' ? blueprintText : argocdText;
    const text = plant(source);
    assert.notEqual(text, source, `${name}: the plant matched nothing`);
    assert.notDeepEqual(findings(kind === 'blueprint' ? text : blueprintText, idpValues, kind === 'argocd' ? text : argocdText), [], name);
  }
  const unannounced = structuredClone(idpValues);
  unannounced.global.podAnnotations['platform/test-accounts'] = 'plane-sign-in plane-sign-in-uninvited';
  assert.notDeepEqual(findings(blueprintText, unannounced, argocdText), [], 'the provider is not told to restart');
});

test('PLANTED INNOCENT: comments naming the group, in the blueprint and inside policy.csv, change nothing the rules hold', () => {
  assert.deepEqual(findings(`# planted comment naming platform-readers and !Env\n${blueprintText}`, idpValues, argocdText), []);
  assert.deepEqual(findings(blueprintText.replace('version: 1', 'version: 1 # planted'), idpValues, argocdText), []);
  const commented = argocdText.replace('g, admins, role:admin\n', 'g, admins, role:admin\n      # platform-readers has no line here\n');
  assert.notEqual(commented, argocdText, 'the plant matched');
  assert.deepEqual(findings(blueprintText, idpValues, commented), []);
});
