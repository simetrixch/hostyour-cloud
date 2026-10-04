import {readFileSync, writeFileSync, lstatSync, realpathSync, readdirSync, lchownSync} from 'node:fs';
import {resolve, join} from 'node:path';
import {digest, isCommit, isUID} from './test-contract.mjs';
import {prepareStaticTools, preparePackageTools, preparePackageLauncher} from './test-tools.mjs';
import {fetchPackages} from './test-package-fetch.mjs';
import {installToolchain} from './test-toolchain-install.mjs';
import {fileURLToPath} from 'node:url';

const registration = JSON.parse(process.env.TEST_REGISTRATION);
const source = realpathSync(process.env.TEST_SOURCE);
if (registration.repositoryURL !== process.env.TEST_REPOSITORY_URL || !isCommit(process.env.TEST_COMMIT) ||
    !isUID(process.env.TEST_RUN_UID)) throw new Error('invalid source identity');
const dependencies = realpathSync(process.env.TEST_DEPENDENCIES);
const recipeDigest = digest(readFileSync(resolve(source, registration.recipeFile)));
const verified = JSON.parse(readFileSync(join(dependencies, 'verified-source.json'), 'utf8'));
if (JSON.stringify(verified) !== JSON.stringify({repositoryURL: registration.repositoryURL, commit: process.env.TEST_COMMIT,
    recipeDigest: registration.recipeDigest, uid: process.env.TEST_RUN_UID}) || recipeDigest !== registration.recipeDigest ||
    recipeDigest !== process.env.TEST_RECIPE_DIGEST) throw new Error('trusted source verification is missing or changed');
if (registration.recipe.packageManager === 'pnpm@11.7.0') {
  if (process.env.TEST_PACKAGE_MANAGER_VERSION !== '11.7.0' || process.env.TEST_REGISTRY_SCOPE !== 'digitaplatform') {
    throw new Error('package-manager identity mismatch');
  }
  await preparePackageTools(join(dependencies, 'tools'));
  preparePackageLauncher(dependencies);
  await fetchPackages(source, registration.recipe.dependencyRoots, dependencies, '/npmrc/.npmrc');
  await installToolchain(dependencies, fileURLToPath(new URL('./test-toolchain/', import.meta.url)), '/npmrc/.npmrc');
} else if (registration.recipe.packageManager !== 'none' || registration.recipe.dependencyRoots.length) {
  throw new Error('unsupported dependency profile');
}
if (registration.recipe.runtime === 'helm' || registration.recipe.suites.some(suite => suite.kind === 'static')) {
  await prepareStaticTools(join(dependencies, 'bin'));
}
function giveSourceToChild(path) {
  const file = lstatSync(path);
  // chown follows symlinks; lchown does not let a source link retitle results.
  lchownSync(path, 1001, 1001);
  if (file.isDirectory()) for (const name of readdirSync(path)) giveSourceToChild(join(path, name));
}
giveSourceToChild(source);
writeFileSync(process.env.TEST_RECIPE_RESULT_PATH, recipeDigest, {mode: 0o600});
