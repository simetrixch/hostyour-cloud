import {writeFileSync} from 'node:fs';
import {runVitest} from './test-vitest.mjs';
import {redact} from './test-contract.mjs';

try {
  const counts = await runVitest(process.env.TEST_PACKAGE_ROOT, process.env.TEST_TOOLCHAIN,
    JSON.parse(process.env.TEST_SUITE_PROFILE), JSON.parse(process.env.TEST_WORKER_ENVIRONMENT));
  writeFileSync(process.env.TEST_VITEST_RESULT, JSON.stringify(counts), {mode: 0o600});
  process.exitCode = counts.passed > 0 && !counts.failed && !counts.skipped ? 0 : 1;
} catch (error) {
  console.error(redact(error.message));
  process.exitCode = 1;
}
