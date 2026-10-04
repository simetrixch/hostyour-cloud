import {readFileSync, writeFileSync, renameSync, rmSync} from 'node:fs';
import {randomUUID} from 'node:crypto';

// This cache is derived from Tekton and GitHub. A damaged entry is reported and
// rebuilt; it must never keep authoritative reconciliation from running.
export function readState(path) {
  try {return JSON.parse(readFileSync(path, 'utf8'));}
  catch (error) {
    if (error.code === 'ENOENT') return;
    if (!(error instanceof SyntaxError)) throw error;
    console.error('reporter state is invalid; rebuilding ' + path);
  }
}

export function writeState(path, value) {
  const temporary = path + '.' + randomUUID() + '.tmp';
  try {
    writeFileSync(temporary, JSON.stringify(value), {mode: 0o600, flag: 'wx'});
    renameSync(temporary, path);
  } finally {rmSync(temporary, {force: true});}
}
