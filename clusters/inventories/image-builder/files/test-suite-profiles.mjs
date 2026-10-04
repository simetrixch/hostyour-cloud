// The reviewed recipe selects a name; it never selects the test tool or an
// executable package.json "test" script. Every counted operation has a fixed
// infrastructure-owned adapter. Builds still run as untrusted preparation.
const vitest = (path, extra = {}) => ({adapter: 'vitest', path, ...extra});
const node = (path, ...files) => ({adapter: 'node', path, files});
const profiles = {
  'digita-auth': {
    backend: vitest('backend', {exclude: ['tests/e2e/cross-service.e2e.test.ts'], env: {
      AUTH_BOOTSTRAP_TOKEN: 'test-bootstrap-token', AUTH_INVITE_TTL_SEC: '259200',
      AUTH_PUBLIC_BASE_URL: 'http://localhost:3100', AUTH_ASSIGNABLE_ROLES: 'Administrator,System User,erp:*,buildproject:*',
      AUTH_LOGIN_AUDIT_RETENTION_DAYS: '90'}}),
    frontend: vitest('frontend', {include: ['src/**/*.test.{ts,tsx}', 'tests/**/*.test.{ts,tsx}']}),
  },
  'digita-jobs': {jobs: vitest('.', {env: {JOBS_ALLOW_DEV_AUTH: 'true', JOBS_BACKOFF_BASE_MS: '10',
    JOBS_CHUNK_TIMEOUT_MS: '5000', JOBS_POLL_INTERVAL_MS: '50', ENGINE_URLS: '{"web":"http://web-engine.test:3000"}'}})},
  'digita-post': {post: vitest('.')},
  'digita-platform': {
    shared: vitest('packages/shared'), theme: vitest('packages/theme'),
    components: vitest('packages/components', {environment: 'jsdom', setupFiles: ['tests/setup.ts']}),
    plugins: vitest('packages/plugins/sdk'),
    engine: vitest('packages/engine', {env: {API_TRUSTED_PROXY_HOPS: '0',
      AUTH_JWKS_URL: 'http://localhost:3100/.well-known/jwks.json', AUTH_ISSUER: 'https://auth.test.local', AUTH_AUDIENCE: 'digita'}}),
    app: vitest('packages/app', {setupFiles: ['tests/setup.ts']}),
    web: vitest('packages/web', {include: ['src/**/*.test.{ts,tsx}', 'tests/**/*.test.{ts,tsx}']}),
  },
  'digita-plugins-free': {
    'design-css': node('build-tools/design-css', 'gen-design-css.test.mjs', 'design-keys.test.mjs'),
    'signature-build': node('build-tools/signature-build', 'signature-keys.test.mjs'),
    'signature-kit': node('build-tools/signature-kit', 'dist/**/*.test.js'),
    usermenu: vitest('usermenu', {environment: 'jsdom'}),
  },
  'digita-plugins-store': {'design-css': node('build-tools/design-css', 'gen-design-css.test.mjs', 'design-keys.test.mjs')},
  'digita-report': {
    backend: vitest('backend', {env: {REPORT_ALLOW_DEV_AUTH: 'true'}}),
    frontend: vitest('frontend', {setupFiles: ['tests/setup-dom-polyfills.ts', 'tests/setup.ts']}),
    'golden-pdf': {adapter: 'golden', path: 'backend'},
  },
};

export function suiteProfile(registration, suite) {
  if (suite.kind === 'static') return [{adapter: 'static', path: '.', command: suite.command}];
  if (suite.command[0] === 'node' && suite.command[1] === '--test') {
    return [node('.', ...suite.command.slice(2))];
  }
  if (['digita-catalog', 'digita-catalog-simetrix'].includes(registration.name) && suite.name === 'catalog') {
    const plan = [node('.', 'build.test.mjs', 'apps/web/tests/**/*.test.mjs', 'apps/workshop/tests/*.test.mjs')];
    if (registration.name === 'digita-catalog') plan.push(node('handbook/tools', 'tests/*.test.mjs'));
    return plan;
  }
  const profile = profiles[registration.name]?.[suite.name];
  if (!profile) throw new Error('required trusted suite adapter is unavailable');
  return [profile];
}
