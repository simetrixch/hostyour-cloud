import {readFileSync, lstatSync, realpathSync, mkdirSync, writeFileSync} from 'node:fs';
import {resolve, relative, dirname, join} from 'node:path';

export const registryHosts = new Set(['registry.npmjs.org', 'npm.pkg.github.com']);

export function registryURL(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || !registryHosts.has(url.hostname) || url.username || url.password ||
      (url.port && url.port !== '443') || url.hash || url.search) throw new Error('unsupported dependency URL');
  return url.href;
}

export function sourceFile(source, path) {
  const absolute = resolve(source, path);
  const inside = relative(source, absolute);
  if (inside.startsWith('../') || inside === '..' || absolute === source) throw new Error('dependency path escaped source');
  let cursor = source;
  for (const segment of inside.split('/')) {
    cursor = join(cursor, segment);
    if (lstatSync(cursor).isSymbolicLink()) throw new Error('symbolic dependency path');
  }
  if (!lstatSync(absolute).isFile() || realpathSync(absolute) !== absolute) throw new Error('invalid dependency file');
  if (lstatSync(absolute).size > 16 * 1024 * 1024) throw new Error('dependency input exceeded limit');
  return absolute;
}

function packageName(name) {
  if (!/^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/i.test(name)) throw new Error('invalid package name');
}

function specifier(value, importer, source) {
  if (typeof value !== 'string' || value.length > 2048 || /[\r\n\x00]/.test(value)) throw new Error('invalid dependency specifier');
  if (value.startsWith('link:')) {
    sourceFile(source, join(importer, value.slice(5), 'package.json'));
    return;
  }
  // Registry aliases, workspace/catalog references and semver are data. Git,
  // local archives, arbitrary URLs and configuration packages are not admitted.
  if (!/^(?:workspace:|catalog:|npm:)?[A-Za-z0-9@/*._^~+<>=| ():-]+$/.test(value) ||
      /(?:https?:|git:|git\+|file:|github:|ssh:|\/\/)/i.test(value)) throw new Error('unsupported dependency protocol');
  if (value.includes(':') && !/^(workspace:|catalog:|npm:)/.test(value)) throw new Error('unsupported dependency protocol');
}

export function sanitizedDependencyRoot(source, root, destination, parse, stringify) {
  const base = resolve(source, root);
  const lock = parse(readFileSync(sourceFile(source, join(root, 'pnpm-lock.yaml')), 'utf8'));
  if (!lock || String(lock.lockfileVersion) !== '9.0' || !lock.importers || !lock.packages || !lock.snapshots ||
      Object.keys(lock).some(key => !['lockfileVersion', 'settings', 'importers', 'packages', 'snapshots'].includes(key))) {
    throw new Error('unsupported dependency lock shape');
  }
  for (const [name, entry] of Object.entries(lock.packages)) {
    if (typeof name !== 'string' || /[\r\n\x00]|(?:https?:|git:|git\+|file:|link:|ssh:)/i.test(name)) throw new Error('unsupported locked package');
    const resolution = entry?.resolution;
    if (!resolution || typeof resolution.integrity !== 'string' || !/^sha(?:512|256|1)-[A-Za-z0-9+/]+={0,2}$/.test(resolution.integrity) ||
        Object.keys(resolution).some(key => !['integrity', 'tarball'].includes(key))) throw new Error('unsupported package resolution');
    if (resolution.tarball) registryURL(resolution.tarball);
  }
  for (const [path, importer] of Object.entries(lock.importers)) {
    const manifestPath = sourceFile(source, join(root, path, 'package.json'));
    if (relative(base, dirname(manifestPath)).startsWith('..')) throw new Error('importer escaped its dependency root');
    const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
    packageName(manifest.name ?? 'cloud-test-root');
    for (const group of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies']) {
      for (const [name, value] of Object.entries(manifest[group] ?? {})) {
        packageName(name); specifier(value, join(root, path), source);
      }
      for (const [name, dependency] of Object.entries(importer[group] ?? {})) {
        packageName(name); specifier(dependency.specifier, join(root, path), source);
        specifier(dependency.version, join(root, path), source);
      }
    }
    // pnpm fetch ignores manifests; a minimal one prevents package-manager
    // downloads and source hooks even if that behavior changes upstream.
    const target = join(destination, path, 'package.json');
    mkdirSync(dirname(target), {recursive: true, mode: 0o700});
    writeFileSync(target, JSON.stringify({name: manifest.name ?? 'cloud-test-root', private: true}), {mode: 0o600});
  }
  for (const entry of Object.values(lock.snapshots)) {
    for (const group of ['dependencies', 'optionalDependencies']) {
      for (const [name, version] of Object.entries(entry[group] ?? {})) {
        packageName(name); specifier(version, root, source);
        if (version.startsWith('link:')) throw new Error('registry package cannot use a source link');
      }
    }
  }
  let workspace = {};
  try {workspace = parse(readFileSync(sourceFile(source, join(root, 'pnpm-workspace.yaml')), 'utf8')) ?? {};}
  catch (error) {if (error.code !== 'ENOENT') throw error;}
  const safeWorkspace = {packages: Object.keys(lock.importers).filter(path => path !== '.'), minimumReleaseAge: 0,
    allowBuilds: {}, ignoreScripts: true, ignorePnpmfile: true, managePackageManagerVersions: false};
  for (const field of ['catalog', 'catalogs']) if (workspace[field]) {
    const groups = field === 'catalog' ? [workspace[field]] : Object.values(workspace[field]);
    for (const group of groups) for (const [name, version] of Object.entries(group)) {packageName(name); specifier(version, root, source);}
    safeWorkspace[field] = workspace[field];
  }
  writeFileSync(join(destination, 'pnpm-workspace.yaml'), stringify(safeWorkspace), {mode: 0o600});
  writeFileSync(join(destination, 'pnpm-lock.yaml'), stringify({...lock, settings: {autoInstallPeers: true, excludeLinksFromLockfile: false}}), {mode: 0o600});
}
