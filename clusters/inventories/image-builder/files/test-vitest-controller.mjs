import {writeSync} from 'node:fs';
import {runVitest} from './test-vitest.mjs';
import {redact} from './test-contract.mjs';

try {
  const counts = await runVitest(process.env.TEST_PACKAGE_ROOT, process.env.TEST_TOOLCHAIN,
    JSON.parse(process.env.TEST_SUITE_PROFILE), JSON.parse(process.env.TEST_WORKER_ENVIRONMENT));
  // Descriptor3 carries the fixed framework summary to the separate supervisor.
  // The framework and Source workers are unprivileged; only the supervisor
  // can write the final SHA/recipe/UID-bound receipt.
  writeSync(3, JSON.stringify(counts));
  process.exitCode = counts.passed > 0 && !counts.failed && !counts.skipped ? 0 : 1;
} catch (error) {
  console.error(redact(error.message));
  process.exitCode = 1;
}
