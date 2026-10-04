import {mkdirSync, mkdtempSync, readFileSync, writeFileSync, chmodSync, rmSync} from 'node:fs';
import {join} from 'node:path';
import {execFileSync} from 'node:child_process';
import {fetchPackages} from './test-package-fetch.mjs';

export async function installToolchain(directory, trustedInputs, authPath) {
  const destination = join(directory, 'toolchain');
  mkdirSync(destination, {mode: 0o755});
  for (const file of ['package.json', 'pnpm-lock.yaml']) {
    writeFileSync(join(destination, file), readFileSync(join(trustedInputs, file)), {mode: 0o644});
  }
  await fetchPackages(destination, ['.'], directory, authPath);
  const homeDirectory = mkdtempSync('/tmp/trusted-toolchain-');
  try {
    // Every package and lock byte here is platform-owned; no repository file
    // participates. Native platform packages are already in the locked store.
    execFileSync(process.execPath, [join(directory, 'tools/pnpm/bin/pnpm.cjs'), 'install', '--offline',
      '--frozen-lockfile', '--ignore-scripts', '--ignore-pnpmfile', '--store-dir', join(directory, 'store'),
      '--config.manage-package-manager-versions=false', '--config.package-manager-strict=false'], {
      cwd: destination, timeout: 15 * 60 * 1000, maxBuffer: 4 * 1024 * 1024,
      env: {PATH: '/usr/local/bin:/usr/bin:/bin', HOME: homeDirectory, CI: 'true',
        NPM_CONFIG_USERCONFIG: '/dev/null', NPM_CONFIG_GLOBALCONFIG: '/dev/null'}});
    chmodSync(destination, 0o755);
  } finally {rmSync(homeDirectory, {recursive: true, force: true});}
}
