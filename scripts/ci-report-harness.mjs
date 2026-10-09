import {spawnSync} from 'node:child_process';
import {chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

// Runs the script of the report task of the ci pipeline against a stand-in curl that answers from fixtures and
// records every call, so scripts/ci-report-failure.test.mjs and scripts/ci-failure-mail.test.mjs read the
// alert it posts. Nothing leaves the machine: the stand-in is the only curl on the PATH.

export const SCRIPT = 'clusters/inventories/consumer-build/files/ci-report-failure.sh';
export const NAMESPACE = 'shop-build';
export const RUN = 'shop-ci-abc12';
export const COMMIT = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';
export const TOKEN = 'token-that-must-not-leave-for-alertmanager';

// The stand-in answers a GET from <fixtures>/<path with / as _>: the body, and <same>.code for an answer
// other than 200 (a missing file is a 404). A pod log honors tailLines, as the API server does. A POST is
// copied to <posts>, answered with $POST_CODE, and every call is logged with whether it carried a header file.
const STAND_IN_CURL = `#!/usr/bin/env bash
out=; data=; auth=; url=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    -w|--max-time|--cacert) shift 2;;
    -H) case "$2" in @*) auth=yes;; esac; shift 2;;
    --data-binary) data="\${2#@}"; shift 2;;
    -sS|-s|-S) shift;;
    *) url="$1"; shift;;
  esac
done
if [ -n "$data" ]; then
  echo "POST $url auth=$auth" >> "$CALLS"
  cp "$data" "$POSTS/$(ls "$POSTS" | wc -l).json"
  echo "stand-in alertmanager answer" > "$out"
  printf '%s' "\${POST_CODE:-200}"
  exit 0
fi
echo "GET $url auth=$auth" >> "$CALLS"
rest="\${url#*://}"; path="/\${rest#*/}"; key="\${path%%\\?*}"; query="\${path#*\\?}"
file="$FIXTURES/$(echo "$key" | tr '/' '_')"
if [ -f "$file.code" ]; then : > "$out"; printf '%s' "$(cat "$file.code")"; exit 0; fi
if [ ! -f "$file" ]; then : > "$out"; printf 404; exit 0; fi
lines="$(echo "$query" | sed -n 's/.*tailLines=\\([0-9]*\\).*/\\1/p')"
if [ -n "$lines" ]; then tail -n "$lines" "$file" > "$out"; else cp "$file" "$out"; fi
printf 200
`;

export const taskRun = (task, {pod = `${RUN}-${task}-pod`, container, ok = true, reason, exitCode = 1, message = ok ? '' : `"step-${task}" exited with code ${exitCode}`, results = {}, steps} = {}) => ({
  status: {
    podName: pod,
    conditions: [{type: 'Succeeded', status: ok ? 'True' : 'False', reason: reason ?? (ok ? 'Succeeded' : 'Failed'), message}],
    steps: steps ?? [{name: task, container: container ?? `step-${task}`, terminated: {exitCode: ok ? 0 : exitCode, reason: ok ? 'Completed' : 'Error'}}],
    results: Object.entries(results).map(([name, value]) => ({name, value})),
  },
});

export const numbered = (count) => Array.from({length: count}, (_, i) => `line ${i + 1}`).join('\n') + '\n';

// A cluster is the run, its TaskRuns by task name, and the logs by pod name.
export const SUCCESSFUL = {
  gate: taskRun('gate', {}), clone: taskRun('clone', {}),
  'describe-commit': taskRun('describe-commit', {ok: true, results: {subject: 'Fix the rounding of VAT', author: 'Ada <ada@example.com>'}, steps: [{name: 'describe', container: 'step-describe', terminated: {exitCode: 0}}]}),
  'fetch-branches': taskRun('fetch-branches', {}), check: taskRun('check', {}),
};
export const withFailure = (task, options = {}, rest = SUCCESSFUL) => ({...rest, [task]: taskRun(task, {ok: false, ...options})});
export const onlyBefore = (task, taskRuns) => {
  const order = ['gate', 'clone', 'describe-commit', 'fetch-branches', 'check'];
  return Object.fromEntries(Object.entries(taskRuns).filter(([name]) => order.indexOf(name) <= order.indexOf(task)));
};

export const execute = ({taskRuns, logs = {}, codes = {}, postCode, env = {}}) => {
  const dir = mkdtempSync(join(tmpdir(), 'ci-report-'));
  try {
    const bin = join(dir, 'bin'), fixtures = join(dir, 'fixtures'), posts = join(dir, 'posts'), serviceAccount = join(dir, 'sa');
    for (const path of [bin, fixtures, posts, serviceAccount]) mkdirSync(path);
    writeFileSync(join(bin, 'curl'), STAND_IN_CURL);
    chmodSync(join(bin, 'curl'), 0o755);
    writeFileSync(join(serviceAccount, 'token'), TOKEN);
    writeFileSync(join(serviceAccount, 'namespace'), NAMESPACE);
    writeFileSync(join(serviceAccount, 'ca.crt'), 'ca');
    const put = (path, body) => writeFileSync(join(fixtures, path.replaceAll('/', '_')), typeof body === 'string' ? body : JSON.stringify(body));
    const api = `/apis/tekton.dev/v1/namespaces/${NAMESPACE}`;
    put(`${api}/pipelineruns/${RUN}`, {metadata: {creationTimestamp: '2026-10-09T10:00:00Z'},
      status: {childReferences: [...Object.keys(taskRuns).map((task) => ({kind: 'TaskRun', name: `${RUN}-${task}`, pipelineTaskName: task})),
        {kind: 'TaskRun', name: `${RUN}-report-failure`, pipelineTaskName: 'report-failure'}]}});
    for (const [task, body] of Object.entries(taskRuns)) put(`${api}/taskruns/${RUN}-${task}`, body);
    for (const [pod, text] of Object.entries(logs)) put(`/api/v1/namespaces/${NAMESPACE}/pods/${pod}/log`, text);
    for (const [path, code] of Object.entries(codes)) {
      put(path, '');
      writeFileSync(join(fixtures, path.replaceAll('/', '_') + '.code'), String(code));
    }
    const result = spawnSync('bash', [SCRIPT], {encoding: 'utf8', env: {
      PATH: bin + ':' + process.env.PATH, HOME: dir,
      CALLS: join(dir, 'calls'), POSTS: posts, FIXTURES: fixtures, POST_CODE: postCode ?? '200',
      SERVICE_ACCOUNT_DIR: serviceAccount, PIPELINE_RUN: RUN, REPOSITORY: 'shop', BRANCH: 'feature/vat', COMMIT,
      DASHBOARD_URL: 'https://tekton.example.test', GRAFANA_URL: 'https://grafana.example.test',
      ALERTMANAGER_URL: 'http://alertmanager.test:9093', KUBERNETES_SERVICE_HOST: 'api.test', KUBERNETES_SERVICE_PORT: '443', ...env}});
    const calls = (() => { try { return readFileSync(join(dir, 'calls'), 'utf8').trim().split('\n'); } catch { return []; } })();
    const alerts = readdirSync(posts).map((name) => JSON.parse(readFileSync(join(posts, name), 'utf8')));
    return {status: result.status, stdout: result.stdout, stderr: result.stderr, calls, alerts, posted: readdirSync(posts).map((name) => readFileSync(join(posts, name), 'utf8'))};
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
};

