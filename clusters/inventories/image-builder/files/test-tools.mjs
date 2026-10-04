import {mkdirSync, writeFileSync, chmodSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {join} from 'node:path';

// Versions and archive hashes come from the upstream release metadata. These
// are infrastructure inputs, never fields from a repository recipe or webhook.
const tools = [
  {name: 'helm', url: 'https://get.helm.sh/helm-v4.3.0-linux-amd64.tar.gz',
    hash: '86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb', member: 'linux-amd64/helm'},
  {name: 'yq', url: 'https://github.com/mikefarah/yq/releases/download/v4.53.6/yq_linux_amd64',
    hash: 'c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385'},
  {name: 'gitleaks', url: 'https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_linux_x64.tar.gz',
    hash: '551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb', member: 'gitleaks'},
];

async function download(tool) {
    const response = await fetch(tool.url, {signal: AbortSignal.timeout(120000)});
    if (!response.ok) throw new Error('could not fetch trusted ' + tool.name);
    const chunks = [];
    let size = 0;
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > 64 * 1024 * 1024) throw new Error('trusted tool archive exceeded its limit');
      chunks.push(chunk);
    }
    const bytes = Buffer.concat(chunks);
    const actual = createHash(tool.algorithm ?? 'sha256').update(bytes).digest(tool.encoding ?? 'hex');
    if (actual !== tool.hash) {
      throw new Error('trusted tool archive mismatch: ' + tool.name);
    }
    return bytes;
}

export async function prepareStaticTools(directory) {
  mkdirSync(directory, {recursive: true, mode: 0o755});
  for (const tool of tools) {
    const bytes = await download(tool);
    const path = join(directory, tool.name);
    if (tool.member) {
      const archive = join(directory, tool.name + '.tgz');
      writeFileSync(archive, bytes, {mode: 0o600});
      const binary = execFileSync('tar', ['-xOzf', archive, tool.member], {maxBuffer: 128 * 1024 * 1024});
      writeFileSync(path, binary, {mode: 0o755});
    } else writeFileSync(path, bytes, {mode: 0o755});
    chmodSync(path, 0o755);
  }
}

export async function preparePackageTools(directory) {
  mkdirSync(directory, {recursive: true, mode: 0o755});
  for (const tool of [
    {name: 'pnpm', url: 'https://registry.npmjs.org/pnpm/-/pnpm-11.7.0.tgz', algorithm: 'sha512', encoding: 'base64',
      hash: 'GcyFLBIMcSV2DyRD7mvgyltA+fUFmN4aCaHxd1A+AQ5Xwjx3ZG4B52HeWb+HT7IqM5jDOrlpH8E+uUa28PTWIA=='},
    {name: 'yaml', url: 'https://registry.npmjs.org/yaml/-/yaml-2.9.0.tgz', algorithm: 'sha512', encoding: 'base64',
      hash: '2AvhNX3mb8zd6Zy7INTtSpl1F15HW6Wnqj0srWlkKLcpYl/gMIMJiyuGq2KeI2YFxUPjdlB+3Lc10seMLtL4cA=='},
  ]) {
    const bytes = await download(tool);
    const archive = join(directory, tool.name + '.tgz');
    const destination = join(directory, tool.name);
    mkdirSync(destination, {mode: 0o755});
    writeFileSync(archive, bytes, {mode: 0o600});
    execFileSync('tar', ['-xzf', archive, '--strip-components=1', '-C', destination], {timeout: 30000});
  }
}

export function preparePackageLauncher(directory) {
  const bin = join(directory, 'bin');
  mkdirSync(bin, {recursive: true, mode: 0o755});
  writeFileSync(join(bin, 'pnpm'), '#!/bin/sh\nexec node "' + join(directory, 'tools/pnpm/bin/pnpm.cjs') + '" "$@"\n', {mode: 0o755});
}
