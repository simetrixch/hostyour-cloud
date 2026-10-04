import {createHash} from 'node:crypto';

export const digest = value => 'sha256:' + createHash('sha256').update(value).digest('hex');
export const isCommit = value => /^[a-f0-9]{40}$/.test(value);
export const isUID = value => /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(value);
export const getParam = (run, name) => run.spec.params?.find(param => param.name === name)?.value;
export const getResult = (run, name) => (run.status?.results ?? run.status?.taskResults ?? []).find(result => result.name === name)?.value;
export const condition = run => run.status?.conditions?.find(value => value.type === 'Succeeded');
export const redact = value => value
  .replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)/g, '[private key withheld]')
  .replace(/\bBearer\s+[A-Za-z0-9_.=-]+/gi, 'Bearer [redacted]')
  .replace(/\b(?:hvs|hvb|hvr)\.[A-Za-z0-9_-]+\b/g, '[Vault token redacted]')
  .replace(/\b(?:mongodb(?:\+srv)?|postgres(?:ql)?|redis(?:s)?):\/\/[^\s'"<>]+/gi, '[connection redacted]')
  .replace(/\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)\b/g, '[token redacted]')
  .replace(/(authorization\s*[:=]\s*|(?:password|private-key|_authToken)\s*[:=]\s*)[^\s,;]+/gi, '$1[redacted]');

export function validateBinding(binding, registration) {
  if (binding.repositoryURL !== registration.repositoryURL || !isCommit(binding.commit) ||
      !isUID(binding.pipelineRun.uid) ||
      !/^[a-z0-9][a-z0-9-]{0,62}$/.test(binding.pipelineRun.name) ||
      binding.pipelineRun.namespace !== registration.name + '-build' ||
      typeof binding.ref !== 'string' || !binding.ref.length || binding.ref.length > 256 ||
      binding.recipeDigest !== registration.recipeDigest ||
      !/^sha256:[a-f0-9]{64}$/.test(binding.runnerDigest)) throw new Error('invalid run binding');
}

export function validateResult(result, binding, registration) {
  validateBinding(binding, registration);
  const fields = ['apiVersion', 'kind', 'repositoryURL', 'ref', 'commit', 'pipelineRun',
    'recipeDigest', 'runnerDigest', 'startedAt', 'completedAt', 'result', 'suites', 'localChecks', 'liveProof', 'notRun'];
  if (!result || Object.keys(result).sort().join() !== fields.sort().join() ||
      result.apiVersion !== 'hostyour.cloud/v1' || result.kind !== 'TestResult') throw new Error('invalid TestResult shape');
  for (const field of ['repositoryURL', 'ref', 'commit', 'recipeDigest', 'runnerDigest']) {
    if (result[field] !== binding[field]) throw new Error('mismatched ' + field);
  }
  if (!result.pipelineRun || Object.keys(result.pipelineRun).sort().join() !== 'name,namespace,uid' ||
      Object.keys(binding.pipelineRun).some(key => result.pipelineRun[key] !== binding.pipelineRun[key])) throw new Error('mismatched PipelineRun');
  if (!['passed', 'failed', 'canceled', 'infrastructure-failed', 'not-run'].includes(result.result)) throw new Error('invalid result');
  const time = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{3})?Z$/;
  if (![result.startedAt, result.completedAt].every(value => typeof value === 'string' && time.test(value) && Number.isFinite(Date.parse(value))) ||
      Date.parse(result.completedAt) < Date.parse(result.startedAt)) throw new Error('invalid result time');
  for (const field of ['localChecks', 'liveProof', 'notRun']) {
    if (!Array.isArray(result[field]) || result[field].length > 200 ||
        result[field].some(value => typeof value !== 'string' || !value.length || value.length > 4096)) throw new Error('invalid ' + field);
  }
  const expected = registration.recipe.suites;
  if (!Array.isArray(result.suites) || result.suites.length !== expected.length) throw new Error('missing required suite');
  for (let index = 0; index < expected.length; index++) {
    const suite = result.suites[index];
    if (Object.keys(suite).sort().join() !== 'cases,kind,name,status' || suite.name !== expected[index].name ||
        suite.kind !== expected[index].kind || !['passed', 'failed', 'skipped', 'not-run'].includes(suite.status) ||
        !suite.cases || Object.keys(suite.cases).sort().join() !== 'failed,passed,skipped' ||
        Object.values(suite.cases).some(value => !Number.isSafeInteger(value) || value < 0)) throw new Error('invalid suite coverage');
  }
  if (Buffer.byteLength(JSON.stringify(result)) > 4096) throw new Error('TestResult exceeds Checks summary limit');
  const passed = result.result === 'passed' && result.notRun.length === 0 && result.suites.every(suite =>
    suite.status === 'passed' && suite.cases.passed > 0 && suite.cases.failed === 0 && suite.cases.skipped === 0);
  if (result.result === 'passed' && !passed) throw new Error('incomplete passing coverage');
  return passed;
}

export function emptyResult(binding, registration, state, explanation, startedAt, completedAt) {
  return {apiVersion: 'hostyour.cloud/v1', kind: 'TestResult', ...binding, startedAt, completedAt,
    result: state, suites: registration.recipe.suites.map(suite => ({name: suite.name, kind: suite.kind,
      status: 'not-run', cases: {passed: 0, failed: 0, skipped: 0}})),
    localChecks: [], liveProof: [], notRun: [explanation]};
}

export function parseNodeTAP(output) {
  // Node's outer harness emits these counters after nested test output. Nested
  // stdout is prefixed as a comment, so it cannot stand in for these lines.
  const matches = [...output.matchAll(/^# tests (\d+)\n# suites (\d+)\n# pass (\d+)\n# fail (\d+)\n# cancelled (\d+)\n# skipped (\d+)\n# todo (\d+)\n# duration_ms [\d.]+\s*$/gm)];
  if (matches.length !== 1) throw new Error('missing authoritative Node test counters');
  const [tests, , passed, failed, canceled, skipped, todo] = matches[0].slice(1).map(Number);
  if (![tests, passed, failed, canceled, skipped, todo].every(Number.isSafeInteger) ||
      tests !== passed + failed + canceled + skipped + todo) throw new Error('inconsistent Node test counters');
  return {passed, failed: failed + canceled, skipped: skipped + todo};
}
