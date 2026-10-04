import {writeFileSync} from 'node:fs';
import {validateBinding, validateResult} from './test-contract.mjs';

const registration = JSON.parse(process.env.TEST_REGISTRATION);
const binding = {repositoryURL: process.env.TEST_REPOSITORY_URL, ref: process.env.TEST_REF,
  commit: process.env.TEST_COMMIT, recipeDigest: process.env.TEST_RECIPE_DIGEST,
  runnerDigest: process.env.TEST_RUNNER_DIGEST,
  pipelineRun: {name: process.env.TEST_RUN_NAME, namespace: process.env.TEST_RUN_NAMESPACE, uid: process.env.TEST_RUN_UID}};
validateBinding(binding, registration);
const latest = process.env.TEST_RECEIPT_MODE === 'latest';
const url = process.env.TEST_REPORTER_URL + (latest ? '/latest/' + binding.pipelineRun.namespace + '/' + binding.commit +
  '?ref=' + encodeURIComponent(binding.ref) : '/receipts/' + binding.pipelineRun.namespace + '/' +
  binding.pipelineRun.name + '/' + binding.pipelineRun.uid);
let receipt;
const deadline = Date.now() + (latest ? 30 : 10) * 60 * 1000;
while (Date.now() < deadline) {
  let response;
  try {response = await fetch(url, {signal: AbortSignal.timeout(Math.max(1, Math.min(10000, deadline - Date.now()))), redirect: 'error'});}
  catch {await new Promise(finish => setTimeout(finish, 5000)); continue;}
  if (response.status === 200) {
    const bytes = await response.text();
    if (Buffer.byteLength(bytes) > 8192) throw new Error('reporter receipt exceeds bound');
    receipt = JSON.parse(bytes);
    break;
  }
  if (![202, 502, 503, 504].includes(response.status)) throw new Error('trusted reporter returned HTTP ' + response.status);
  await new Promise(finish => setTimeout(finish, 5000));
}
if (!receipt || (!latest && receipt.binding?.pipelineRun?.uid !== binding.pipelineRun.uid) ||
    (latest && receipt.completed !== true)) throw new Error('trusted reporter receipt is missing or provisional');
const expected = latest ? {...binding, pipelineRun: receipt.binding?.pipelineRun} : binding;
const passed = validateResult(receipt.result, expected, registration);
if (receipt.passed !== passed) throw new Error('trusted receipt conclusion disagrees with coverage');
writeFileSync(process.env.TEST_PASSED_PATH, String(passed));
writeFileSync(process.env.TEST_RECEIPT_PATH, JSON.stringify(receipt.result));
process.exitCode = process.env.TEST_REQUIRE_SUCCESS === 'true' && !passed ? 1 : 0;
