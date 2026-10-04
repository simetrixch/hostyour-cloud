import childProcess from 'node:child_process';
import {syncBuiltinESMExports} from 'node:module';
import {pathToFileURL} from 'node:url';
import {join} from 'node:path';
import {existsSync} from 'node:fs';

// This controller uses an infrastructure-owned Vitest and configuration. Only
// its forked workers may import repository code, under the untrusted UID.
export async function runVitest(root, toolchain, profile, environment) {
  const originalFork = childProcess.fork;
  childProcess.fork = (module, args, options = {}) => originalFork(module, args, {...options, uid: 1001, gid: 1001});
  syncBuiltinESMExports();
  let context;
  try {
    const {startVitest} = await import(pathToFileURL(join(toolchain, 'node_modules/vitest/dist/node.js')));
    const setupFiles = (profile.setupFiles ?? []).map(file => join(root, file));
    if (setupFiles.some(file => !existsSync(file))) throw new Error('required suite setup file is missing');
    context = await startVitest('test', [], {root, config: false, watch: false, pool: 'forks',
      maxWorkers: 1, fileParallelism: false, isolate: true, globals: true, environment: profile.environment ?? 'node',
      include: profile.include ?? ['tests/**/*.test.{ts,tsx}'], setupFiles,
      exclude: ['**/node_modules/**', '**/.git/**', ...(profile.exclude ?? [])],
      passWithNoTests: false, testTimeout: 30000, hookTimeout: 120000,
      env: environment, css: false, coverage: {enabled: false}, reporters: ['default']}, {
      configFile: false, envFile: false, cacheDir: process.env.TEST_TRUSTED_CACHE,
      resolve: {alias: [
        {find: /^vitest$/, replacement: join(toolchain, 'node_modules/vitest/dist/index.js')},
        {find: '@', replacement: join(root, 'src')},
      ]}, css: {postcss: {plugins: []}},
      oxc: {jsx: {runtime: 'automatic'}}, server: {host: '127.0.0.1', allowedHosts: []},
    });
    const counts = {passed: 0, failed: 0, skipped: 0};
    const visit = task => {
      if (task.type === 'test') {
        if (task.result?.state === 'pass') counts.passed++;
        else if (task.result?.state === 'fail') counts.failed++;
        else counts.skipped++;
      } else for (const child of task.tasks ?? []) visit(child);
    };
    const files = context.state.getFiles();
    for (const file of files) visit(file);
    if (context.state.getUnhandledErrors().length || files.some(file => file.result?.state === 'fail') && !counts.failed) {
      throw new Error('Vitest collection, setup, teardown or unhandled errors prevented required coverage');
    }
    if (!files.length || !counts.passed && !counts.failed && !counts.skipped) throw new Error('required Vitest coverage is empty');
    return counts;
  } finally {
    await context?.close();
    childProcess.fork = originalFork;
    syncBuiltinESMExports();
  }
}
