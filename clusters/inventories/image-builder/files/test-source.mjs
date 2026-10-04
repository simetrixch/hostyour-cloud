import {readFileSync, writeFileSync, lstatSync, realpathSync, rmSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {resolve, join} from 'node:path';
import {digest, isCommit, isUID} from './test-contract.mjs';

const registration = JSON.parse(process.env.TEST_REGISTRATION);
const source = realpathSync(process.env.TEST_SOURCE);
if (registration.repositoryURL !== process.env.TEST_REPOSITORY_URL || !isCommit(process.env.TEST_COMMIT) ||
    !isUID(process.env.TEST_RUN_UID)) throw new Error('invalid source identity');
const commit = execFileSync('git', ['-C', source, '-c', 'core.hooksPath=/dev/null', 'rev-parse', 'HEAD'],
  {encoding: 'utf8', env: {PATH: '/usr/local/bin:/usr/bin:/bin', HOME: '/tmp'}}).trim();
const origin = execFileSync('git', ['-C', source, 'remote', 'get-url', 'origin'],
  {encoding: 'utf8', env: {PATH: '/usr/local/bin:/usr/bin:/bin', HOME: '/tmp'}}).trim();
if (commit !== process.env.TEST_COMMIT || origin !== registration.repositoryURL) throw new Error('cloned repository or commit mismatch');
for (const path of ['deploy', registration.recipeFile]) {
  if (lstatSync(resolve(source, path)).isSymbolicLink()) throw new Error('symbolic recipe path');
}
const recipeDigest = digest(readFileSync(resolve(source, registration.recipeFile)));
if (recipeDigest !== registration.recipeDigest || recipeDigest !== process.env.TEST_RECIPE_DIGEST) throw new Error('source recipe is not the reviewed recipe');
// Existing static checks need the tracked-file list and immutable HEAD. Keep
// those, replacing all clone configuration and hooks before source execution.
const git = join(source, '.git');
if (!lstatSync(git).isDirectory() || lstatSync(git).isSymbolicLink()) throw new Error('invalid Git metadata');
rmSync(join(git, 'hooks'), {recursive: true, force: true});
writeFileSync(join(git, 'config'), '[core]\n repositoryformatversion = 0\n bare = false\n hooksPath = /dev/null\n[remote "origin"]\n url = ' + registration.repositoryURL + '\n', {mode: 0o600});
writeFileSync(join(realpathSync(process.env.TEST_DEPENDENCIES), 'verified-source.json'), JSON.stringify({
  repositoryURL: registration.repositoryURL, commit, recipeDigest, uid: process.env.TEST_RUN_UID,
}), {mode: 0o600, flag: 'wx'});

if (registration.name === 'digita-platform') {
  const fixtures = realpathSync(process.env.TEST_FIXTURES);
  for (const fixture of JSON.parse(process.env.TEST_FIXTURE_REGISTRATIONS)) {
    if (!/^[a-z0-9-]+$/.test(fixture.name) || !isCommit(fixture.commit)) throw new Error('invalid fixed fixture identity');
    const directory = realpathSync(resolve(fixtures, fixture.name));
    if (directory !== resolve(fixtures, fixture.name)) throw new Error('symbolic fixture directory');
    const options = {encoding: 'utf8', env: {PATH: '/usr/local/bin:/usr/bin:/bin', HOME: '/tmp'}};
    const head = execFileSync('git', ['-C', directory, '-c', 'core.hooksPath=/dev/null', 'rev-parse', 'HEAD'], options).trim();
    const origin = execFileSync('git', ['-C', directory, 'remote', 'get-url', 'origin'], options).trim();
    if (head !== fixture.commit || origin !== fixture.repositoryURL) throw new Error('immutable fixture checkout mismatch');
    // No Git identity, credential configuration or hook reaches Source tests.
    rmSync(join(directory, '.git'), {recursive: true, force: true});
  }
}
