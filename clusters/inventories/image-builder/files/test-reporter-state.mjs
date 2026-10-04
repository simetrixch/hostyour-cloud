import {condition} from './test-contract.mjs';
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

// Preserve only already-published terminal history across a worker rollout.
// Legacy records predate the completed field; explicit provisional ones do not.
export function historicalReceipt(cached, run, binding) {
  const receipt = cached?.receipt;
  const old = receipt?.binding;
  if ((receipt?.completed === true || (receipt && !Object.hasOwn(receipt, 'completed'))) &&
      condition(run)?.status === 'True' && !/cancel|stop/i.test(run.spec.status ?? '') &&
      old?.repositoryURL === binding.repositoryURL && old?.commit === binding.commit && old?.ref === binding.ref &&
      JSON.stringify(old.pipelineRun) === JSON.stringify(binding.pipelineRun) &&
      (old.runnerDigest !== binding.runnerDigest || old.recipeDigest !== binding.recipeDigest)) return receipt;
}
