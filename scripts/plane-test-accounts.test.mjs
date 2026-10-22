import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readdirSync, readFileSync} from 'node:fs';
import test from 'node:test';

// The two accounts of the Plane sign-in proof (digita-testkit cases/plane-sign-in.spec.ts): one that Plane
// holds an invitation for, one it does not. Both are declared here and made by the identity provider, each
// with the password of its own Vault value, and both are members of the group plane-users alone, a group
// that grants no administrator right in Authentik, Forgejo or Plane, and reaches no application of the identity
// provider but the two the sign-in of Plane passes through: an application without a binding admits every
// account, and one of these accounts would then reach the Tekton Dashboard, which creates a TaskRun anywhere.

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

const blueprintDirectory = 'clusters/bootstrap/idp/blueprints';
const blueprintTexts = Object.fromEntries(readdirSync(blueprintDirectory).filter(name => name.endsWith('.yaml')).sort()
  .map(name => [name, readFileSync(`${blueprintDirectory}/${name}`, 'utf8')]));

// The group an application admits beside `admins`. Plane's sign-in passes through two applications, the forward auth of
// Plane and Forgejo, which Plane signs in through, and both admit plane-users. The sign-in proof of the two consoles
// passes through Argo CD, Headlamp's own client and the forward auth in front of Headlamp, and all three admit
// platform-readers (21-platform-test-accounts.yaml). Every other application admits `admins` alone.
const ADMITTED_BESIDE_ADMINS = {
  forgejo: 'plane-users', plane: 'plane-users',
  argocd: 'platform-readers', headlamp: 'platform-readers', 'headlamp-forward-auth': 'platform-readers',
};

/** Every way an application of the blueprints admits more than staff, or a sign-in group anywhere but the applications of its sign-in, named. */
function accessFindings(texts) {
  const found = [];
  const applications = [];
  for (const [file, text] of Object.entries(texts)) {
    const blueprint = JSON.parse(execFileSync('yq', ['-o=json', '.', '-'], {input: text, encoding: 'utf8'}));
    const waitsFor = JSON.stringify(blueprint.conditions ?? []);
    for (const entry of blueprint.entries ?? []) {
      if (entry.model === 'authentik_core.application') applications.push({slug: entry.identifiers.slug, mode: entry.attrs.policy_engine_mode, bindings: []});
    }
    for (const entry of (blueprint.entries ?? []).filter(e => e.model === 'authentik_policies.policybinding')) {
      const {target, group, policy, user} = entry.identifiers;
      if (target?.[0] !== 'authentik_core.application') continue;
      const application = applications.find(a => a.slug === target[1][1]);
      const where = `${file} binds ${target[1][1]}`;
      if (policy !== undefined || user !== undefined || group?.[0] !== 'authentik_core.group') { found.push(`${where} by something other than a group`); continue; }
      if (entry.attrs?.enabled !== true) found.push(`${where} to ${group[1][1]} with a binding that is not enabled`);
      if (entry.attrs?.negate) found.push(`${where} to ${group[1][1]} with a binding that is negated`);
      if (!waitsFor.includes(JSON.stringify(group))) found.push(`${file} does not wait for the group ${group[1][1]}, so its binding fails at a first start`);
      (application?.bindings ?? []).push(group[1][1]);
    }
  }
  for (const {slug, mode, bindings} of applications) {
    const admitted = [...bindings].sort();
    const expected = slug in ADMITTED_BESIDE_ADMINS ? ['admins', ADMITTED_BESIDE_ADMINS[slug]].sort() : ['admins'];
    if (JSON.stringify(admitted) !== JSON.stringify(expected)) found.push(`${slug} admits ${JSON.stringify(admitted)}, not ${JSON.stringify(expected)} alone`);
    if (bindings.length > 1 && mode !== 'any') found.push(`${slug} has ${bindings.length} bindings under the mode ${mode}, so a member of one group is refused by the other`);
  }
  if (applications.length === 0) found.push('no application was read');
  return found;
}

test('every application admits the group admins, only Plane and Forgejo admit plane-users beside it, and only Argo CD and Headlamp admit platform-readers', () => {
  assert.deepEqual(accessFindings(blueprintTexts), []);
});

const waitsForReaders = text => text.replace('conditions:\n', 'conditions:\n  - !Find [authentik_core.group, [name, platform-readers]]\n');
const readersBinding = slug => `  - id: planted-readers-binding\n    model: authentik_policies.policybinding\n    identifiers:\n      target: !Find [authentik_core.application, [slug, ${slug}]]\n      group: !Find [authentik_core.group, [name, platform-readers]]\n      order: 5\n    attrs:\n      enabled: true\n`;

test('PLANTED DEFECT: an application without a binding, a third or a wrong group, a binding by user or negated, or a wrong mode is found', () => {
  const planted = {
    'tekton-dashboard without its binding': ['99-proxy-tekton.yaml', text => text.replace(/  - id: tekton-admins-binding[\s\S]*$/, '')],
    'plane-users admitted to the tekton-dashboard': ['99-proxy-tekton.yaml', text => text.replace('name, admins', 'name, plane-users')],
    'a new application without a binding': ['99-grafana.yaml', text => `${text}  - id: planted-app\n    model: authentik_core.application\n    identifiers:\n      slug: planted\n    attrs:\n      name: Planted\n      slug: planted\n`],
    'the group everyone admitted to grafana': ['99-grafana.yaml', text => text.replace('name, admins', 'name, everyone')],
    'a binding of grafana by user': ['99-grafana.yaml', text => text.replace(/group: !Find \[authentik_core.group, \[name, admins\]\]/, 'user: 1')],
    'a negated binding of vault': ['99-vault.yaml', text => text.replace('enabled: true', 'enabled: true\n      negate: true')],
    'a disabled binding of vault': ['99-vault.yaml', text => text.replace('enabled: true', 'enabled: false')],
    'plane without plane-users': ['99-proxy-plane.yaml', text => text.replace(/  - id: plane-plane-users-binding[\s\S]*$/, '')],
    'plane under the mode all': ['99-proxy-plane.yaml', text => text.replace('policy_engine_mode: any', 'policy_engine_mode: all')],
    'a binding that does not wait for admins': ['99-argocd.yaml', text => text.replace('  - !Find [authentik_core.group, [name, admins]]\n', '')],
    'plane-users admitted to argocd': ['99-argocd.yaml', text => text.replace('group: !Find [authentik_core.group, [name, platform-readers]]', 'group: !Find [authentik_core.group, [name, plane-users]]')
      .replace('  - !Find [authentik_core.group, [name, platform-readers]]\n', '  - !Find [authentik_core.group, [name, plane-users]]\n')],
    'platform-readers admitted to plane': ['99-proxy-plane.yaml', text => waitsForReaders(text) + readersBinding('plane')],
    'platform-readers admitted to the tekton-dashboard': ['99-proxy-tekton.yaml', text => waitsForReaders(text) + readersBinding('tekton-dashboard')],
    'argocd without its platform-readers binding': ['99-argocd.yaml', text => text.replace(/  - id: argocd-platform-readers-binding[\s\S]*$/, '')],
    'headlamp-forward-auth without its platform-readers binding': ['99-proxy-headlamp.yaml', text => text.replace(/  - id: headlamp-forward-auth-platform-readers-binding[\s\S]*$/, '')],
    'argocd with two bindings and no policy_engine_mode': ['99-argocd.yaml', text => text.replace(/\n      # The OR across the bindings[^\n]*\n      policy_engine_mode: any/, '')],
    'a binding of platform-readers that does not wait for the group': ['99-headlamp.yaml', text => text.replace('  - !Find [authentik_core.group, [name, platform-readers]]\n', '')],
  };
  for (const [name, [file, plant]] of Object.entries(planted)) {
    const text = plant(blueprintTexts[file]);
    assert.notEqual(text, blueprintTexts[file], `${name}: the plant matched nothing`);
    assert.notDeepEqual(accessFindings({...blueprintTexts, [file]: text}), [], name);
  }
});

test('PLANTED INNOCENT: a comment, and a new application that admits admins alone, change nothing the rules hold', () => {
  assert.deepEqual(accessFindings({...blueprintTexts, '99-vault.yaml': `# planted comment naming plane-users\n${blueprintTexts['99-vault.yaml']}`}), []);
  assert.deepEqual(accessFindings({...blueprintTexts, '99-argocd.yaml': `# planted comment naming platform-readers\n${blueprintTexts['99-argocd.yaml']}`}), []);
  const added = `${blueprintTexts['99-grafana.yaml']}  - id: planted-app\n    model: authentik_core.application\n    identifiers:\n      slug: planted\n    attrs:\n      name: Planted\n      slug: planted\n`
    + '  - id: planted-binding\n    model: authentik_policies.policybinding\n    identifiers:\n      target: !Find [authentik_core.application, [slug, planted]]\n      group: !Find [authentik_core.group, [name, admins]]\n      order: 0\n    attrs:\n      enabled: true\n';
  assert.deepEqual(accessFindings({...blueprintTexts, '99-grafana.yaml': added.replace('conditions:\n', 'conditions:\n  - !Find [authentik_core.group, [name, admins]]\n')}), []);
});
