import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const path = fileURLToPath(new URL('../clusters/bootstrap/idp/blueprints/99-post.yaml', import.meta.url));
const read = expression => JSON.parse(execFileSync('yq', ['-o=json', expression, path], {encoding: 'utf8'}));
const blueprint = read('.');
const provider = blueprint.entries.find(entry => entry.id === 'post-provider');
const allowed = ['', '.dev', '.test'].flatMap(stage => ['/api/auth/callback', '/'].map(route => ({
  matching_mode: 'strict', url: [`https://post${stage}.%s${route}`, 'IDP_UNIT_APEX']
})));
const checkAllowlist = entries => assert.deepEqual(entries, allowed);

test('PROD, DEV and TEST admit exactly their strict callback/logout URLs with Authentik tags', () => {
  checkAllowlist(provider.attrs.redirect_uris);
  const tags = read('[.entries[] | select(.id == "post-provider") | .attrs.redirect_uris[] | {"url": (.url | tag), "apex": (.url[1] | tag)}]');
  assert.deepEqual(tags, allowed.map(() => ({url: '!Format', apex: '!Env'})));
  for (const apex of ['unit.example.com', 'new.example.net']) {
    const actual = provider.attrs.redirect_uris.map(entry => entry.url[0].replace('%s', apex));
    assert.deepEqual(actual, ['prod', 'dev', 'test'].flatMap(stage => {
      const host = `post.${stage === 'prod' ? apex : `${stage}.${apex}`}`;
      return [`https://${host}/api/auth/callback`, `https://${host}/`];
    }));
  }
});

test('the original PROD-only list and redirect widening fail the same allowlist check', () => {
  assert.throws(() => checkAllowlist(allowed.slice(0, 2)));
  for (const replacement of [
    {...allowed[2], matching_mode: 'regex'},
    {...allowed[2], matching_mode: 'wildcard'},
    {matching_mode: 'strict', url: ['https://*.example.com/', 'IDP_UNIT_APEX']},
    {matching_mode: 'strict', url: ['https://foreign.example.com/', 'IDP_UNIT_APEX']},
    {matching_mode: 'strict', url: ['https://user:password@post.dev.%s/', 'IDP_UNIT_APEX']},
  ]) {
    const changed = structuredClone(allowed);
    changed[2] = replacement;
    assert.throws(() => checkAllowlist(changed));
  }
  assert.throws(() => checkAllowlist([...allowed, allowed[0]]));
});

test('the existing confidential client, grants and single admins-only binding remain intact', () => {
  assert.equal(provider.model, 'authentik_providers_oauth2.oauth2provider');
  assert.equal(provider.attrs.client_type, 'confidential');
  assert.equal(provider.attrs.client_id, 'post');
  assert.equal(provider.attrs.client_secret, 'IDP_POST_CLIENT_SECRET');
  assert.deepEqual(provider.attrs.grant_types, ['authorization_code', 'refresh_token']);
  assert.deepEqual(provider.attrs.authorization_flow, ['authentik_flows.flow', ['slug', 'default-provider-authorization-implicit-consent']]);
  assert.deepEqual(provider.attrs.invalidation_flow, ['authentik_flows.flow', ['slug', 'default-provider-invalidation-flow']]);
  assert.deepEqual(blueprint.conditions, [['authentik_core.group', ['name', 'admins']]]);
  const bindings = blueprint.entries.filter(entry => entry.model === 'authentik_policies.policybinding');
  assert.equal(bindings.length, 1);
  assert.deepEqual(bindings[0].identifiers, {
    target: ['authentik_core.application', ['slug', 'post']],
    group: ['authentik_core.group', ['name', 'admins']], order: 0,
  });
  assert.deepEqual(bindings[0].attrs, {enabled: true});
  const app = blueprint.entries.find(entry => entry.id === 'post-app');
  assert.deepEqual(app.attrs.provider, ['authentik_providers_oauth2.oauth2provider', ['name', 'Post']]);
  assert.equal(app.attrs.policy_engine_mode, 'any');
});
