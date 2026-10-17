import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import test from 'node:test';

// The two accounts of the Plane sign-in proof (digita-testkit cases/plane-sign-in.spec.ts): one that Plane
// holds an invitation for, one it does not. Both are declared here and made by the identity provider, each
// with the password of its own Vault value, and both are members of the group plane-users alone, a group
// that grants no administrator right in Authentik, Forgejo or Plane.

const blueprintFile = 'clusters/bootstrap/idp/blueprints/20-plane-test-accounts.yaml';
const blueprintText = readFileSync(blueprintFile, 'utf8');
const idpValues = JSON.parse(execFileSync('yq', ['-o=json', '.', 'clusters/bootstrap/idp/values.yaml'], {encoding: 'utf8'}));

const GROUP = 'plane-users';
const ACCOUNTS = [
  {username: 'plane-sign-in', email: 'simplidigita.ai+plane-sign-in@gmail.com', password: 'IDP_PLANE_TEST_ACCOUNT_PASSWORD'},
  {username: 'plane-sign-in-uninvited', email: 'simplidigita.ai+plane-sign-in-uninvited@gmail.com', password: 'IDP_PLANE_TEST_UNINVITED_PASSWORD'},
];

/** Every way the blueprint breaks the rules above, named. */
function findings(text, values) {
  const found = [];
  const blueprint = JSON.parse(execFileSync('yq', ['-o=json', '.', '-'], {input: text, encoding: 'utf8'}));
  const tag = path => execFileSync('yq', [`${path} | tag`, '-'], {input: text, encoding: 'utf8'}).trim();
  const groups = blueprint.entries.filter(e => e.model === 'authentik_core.group');
  if (groups.length !== 1 || groups[0].identifiers.name !== GROUP) return [...found, `the groups are ${groups.map(g => g.identifiers.name)}, not ${GROUP} alone`];
  const [group] = groups;
  if (group.state !== 'created') found.push(`the group ${GROUP} is ${group.state ?? 'present'}, so a reconcile would wipe the members the sign-in adds`);
  if (group.attrs?.is_superuser) found.push(`the group ${GROUP} makes its members superusers`);
  if (Object.keys(group.attrs ?? {}).some(key => !['name'].includes(key))) found.push(`the group ${GROUP} carries attributes beyond its name: ${Object.keys(group.attrs)}`);
  const users = blueprint.entries.filter(e => e.model === 'authentik_core.user');
  if (JSON.stringify(users.map(u => u.identifiers.username)) !== JSON.stringify(ACCOUNTS.map(a => a.username))) return [...found, `the accounts are ${users.map(u => u.identifiers.username)}`];
  users.forEach((user, index) => {
    const account = ACCOUNTS[index];
    const where = `the account ${account.username}`;
    if (user.attrs.email !== account.email) found.push(`${where} has the address ${user.attrs.email}`);
    if (user.attrs.is_active !== true) found.push(`${where} is not active`);
    if (user.attrs.password !== account.password || tag(`.entries[${blueprint.entries.indexOf(user)}].attrs.password`) !== '!Env') found.push(`${where} does not take its password from !Env ${account.password}`);
    if (JSON.stringify(user.attrs.groups) !== JSON.stringify([group.id]) || tag(`.entries[${blueprint.entries.indexOf(user)}].attrs.groups[0]`) !== '!KeyOf') found.push(`${where} is in other groups than ${GROUP}`);
    if (user.attrs.is_superuser || user.attrs.attributes?.['goauthentik.io/user/superuser']) found.push(`${where} is a superuser`);
    if (user.attrs.type !== undefined && user.attrs.type !== 'internal') found.push(`${where} is of the type ${user.attrs.type}`);
  });
  if (group.id === undefined) found.push(`the group ${GROUP} has no id, so no account can refer to it`);
  if (!values.global.podAnnotations['platform/test-accounts'].split(' ').includes('plane-sign-in')) found.push('platform/test-accounts does not list plane-sign-in, so the provider never restarts onto the new passwords');
  return found;
}

test('the blueprint declares the invited and the uninvited account in the group plane-users alone, with !Env passwords', () => {
  assert.deepEqual(findings(blueprintText, idpValues), []);
});

test('PLANTED DEFECT: an administrator group, a literal password, a superuser, another address or a re-asserted group is found', () => {
  const planted = {
    'a member of admins': text => text.replace(/groups:\n(\s+)- !KeyOf plane-users-group/, 'groups:\n$1- !KeyOf plane-users-group\n$1- !Find [authentik_core.group, [name, admins]]'),
    'a literal password': text => text.replace('!Env IDP_PLANE_TEST_ACCOUNT_PASSWORD', 'hunter2-hunter2'),
    'a password of the other account': text => text.replace('!Env IDP_PLANE_TEST_UNINVITED_PASSWORD', '!Env IDP_PLANE_TEST_ACCOUNT_PASSWORD'),
    'a superuser': text => text.replace('is_active: true', 'is_active: true\n      is_superuser: true'),
    'a group of superusers': text => text.replace(/(id: plane-users-group[\s\S]*?attrs:\n\s+name: plane-users)/, '$1\n      is_superuser: true'),
    'a group re-asserted at every reconcile': text => text.replace('\n    state: created\n', '\n    state: present\n'),
    'another address': text => text.replace('simplidigita.ai+plane-sign-in@gmail.com', 'owner@example.com'),
    'the bare test mailbox': text => text.replace('simplidigita.ai+plane-sign-in-uninvited@gmail.com', 'simplidigita.ai@gmail.com'),
  };
  for (const [name, plant] of Object.entries(planted)) {
    const text = plant(blueprintText);
    assert.notEqual(text, blueprintText, `${name}: the plant matched nothing`);
    assert.notDeepEqual(findings(text, idpValues), [], name);
  }
  const unannounced = structuredClone(idpValues);
  unannounced.global.podAnnotations['platform/test-accounts'] = '';
  assert.notDeepEqual(findings(blueprintText, unannounced), [], 'the provider is not told to restart');
});

test('PLANTED INNOCENT: a comment on top and a comment after the version change nothing the rules hold', () => {
  assert.deepEqual(findings(`# planted comment naming plane-users and !Env\n${blueprintText}`, idpValues), []);
  assert.deepEqual(findings(blueprintText.replace('version: 1', 'version: 1 # planted'), idpValues), []);
});
