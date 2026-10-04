import {writeFileSync} from 'node:fs';
import {validateBinding, validateResult} from './test-contract.mjs';

const registration = JSON.parse(process.env.TEST_REGISTRATION);
const binding = {repositoryURL: process.env.TEST_REPOSITORY_URL, ref: process.env.TEST_REF,
  commit: process.env.TEST_COMMIT, recipeDigest: process.env.TEST_RECIPE_DIGEST,
  runnerDigest: process.env.TEST_RUNNER_DIGEST,
  pipelineRun: {name: process.env.TEST_RUN_NAME, namespace: process.env.TEST_RUN_NAMESPACE, uid: process.env.TEST_RUN_UID}};
validateBinding(binding, registration);
const url = process.env.TEST_REPORTER_URL + '/receipts/' + binding.pipelineRun.namespace + '/' +
  binding.pipelineRun.name + '/' + binding.pipelineRun.uid;
let receipt;
for (let attempt = 0; attempt < 60; attempt++) {
  let response;
  try {response = await fetch(url, {signal: AbortSignal.timeout(10000), redirect: 'error'});}
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
if (!receipt || receipt.binding?.pipelineRun?.uid !== binding.pipelineRun.uid) throw new Error('trusted reporter receipt is missing');
const passed = validateResult(receipt.result, binding, registration);
if (receipt.passed !== passed) throw new Error('trusted receipt conclusion disagrees with coverage');
writeFileSync(process.env.TEST_PASSED_PATH, String(passed));
writeFileSync(process.env.TEST_RECEIPT_PATH, JSON.stringify(receipt.result));
process.exitCode = process.env.TEST_REQUIRE_SUCCESS === 'true' && !passed ? 1 : 0;
