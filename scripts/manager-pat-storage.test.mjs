import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';

const template = readFileSync(new URL('../secrets/secrets.example', import.meta.url), 'utf8');
const managerKey = 'BUILD_HOSTYOUR_MANAGER_REPO_PAT';

function assertNoManagerPatStorage(text) {
  assert.equal(text.includes(managerKey), false, 'the secrets template still declares Manager PAT storage');
  assert.equal(text.includes('secret/build/hostyour-manager/repo-pat'), false, 'the template still describes the removed Manager PAT seed');
}

test('the secrets template has no unused Manager PAT storage or seed instructions', () => {
  assertNoManagerPatStorage(template);
});

test('PLANTED DEFECT: the obsolete Manager PAT key and seed instructions are each rejected', () => {
  for (const leftover of [`${managerKey}=\n`, '# secret/build/hostyour-manager/repo-pat\n']) {
    assert.throws(() => assertNoManagerPatStorage(template + leftover), /Manager PAT/);
  }
});

test('PLANTED INNOCENT: the cloud bump PAT entry remains valid', () => {
  assert.match(template, /^BUILD_HOSTYOUR_CLOUD_REPO_PAT=$/m);
  assertNoManagerPatStorage('BUILD_HOSTYOUR_CLOUD_REPO_PAT=\n');
});
