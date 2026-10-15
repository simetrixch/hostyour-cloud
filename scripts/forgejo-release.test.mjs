import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import {execFileSync, spawnSync} from 'node:child_process';
import {chmodSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {renderChart} from './render-chart.mjs';

// The Forgejo release flow. A Forgejo delivery, signed with Forgejo's own key, starts the Pipeline
// forgejo-release in forgejo-build: the commit status, the clone, the image pushed to Zot, and on a
// tag the Forgejo release and the Plane update. The runs pass the PipelineRun guard like a unit's,
// the API tokens reach the three API Tasks alone, a GitHub delivery starts nothing here and a Forgejo
// delivery nothing of GitHub's, and the scripts the Tasks run are run here against a stand-in curl.

const FILES = 'clusters/inventories/image-builder/files';
const SHA = 'a1b2c3d4e5f60718293a4b5c6d7e8f9012345678';

// ── The scripts, against a stand-in curl ──────────────────────────────────────────────────────────
// The stand-in logs its arguments, keeps the header it reads on its standard input and the bodies it
// is given, records every header it is handed as a file instead, and answers by
// method and path from the ANSWERS file: one line per answer, `<METHOD> <path-suffix> <code> <json>`.
const STAND_IN_CURL = `#!/usr/bin/env bash
echo "$*" >> "$CALLS"
out=; url=; method=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    -X) method="$2"; shift 2;;
    -H) case "$2" in @-) cat > "$SEEN/auth";; @*) echo "\${2#@}" >> "$SEEN/header-files";; esac; shift 2;;
    --data-binary) n=$(ls "$SEEN" | wc -l); cp "\${2#@}" "$SEEN/body-$n.json"; shift 2;;
    -w|--max-time) shift 2;;
    -*) shift;;
    *) url="$1"; shift;;
  esac
done
echo "$method $url" >> "$SEEN/requests"
while read -r m suffix code answer; do
  case "$method $url" in "$m "*"$suffix") printf '%s' "$answer" > "$out"; printf '%s' "$code"; exit 0;; esac
done < "$ANSWERS"
printf '{"message":"no stand-in answer"}' > "$out"; printf 404
`;

const git = (cwd, ...args) => execFileSync('git', ['-c', 'user.name=check', '-c', 'user.email=check@example.invalid', ...args], {cwd, encoding: 'utf8'}).trim();

/** Runs a script text with env, answers and an optional repository; returns what it did. */
function execute(scriptText, env, answers = [], commits = null) {
  const dir = mkdtempSync(join(tmpdir(), 'forgejo-release-'));
  try {
    const bin = join(dir, 'bin'), seen = join(dir, 'seen'), repo = join(dir, 'repo');
    mkdirSync(bin); mkdirSync(seen); mkdirSync(repo);
    writeFileSync(join(bin, 'curl'), STAND_IN_CURL); chmodSync(join(bin, 'curl'), 0o755);
    writeFileSync(join(dir, 'script.sh'), scriptText);
    const shas = [];
    if (commits) {
      git(repo, 'init', '-q', '-b', 'main');
      for (const message of commits) { git(repo, 'commit', '-q', '--allow-empty', '-m', message); shas.push(git(repo, 'rev-parse', 'HEAD')); }
    }
    const fill = text => text.replace(/\$\{SHA(\d)\}/g, (_, i) => shas[Number(i)]);
    writeFileSync(join(dir, 'answers'), answers.map(fill).join('\n') + '\n');
    const result = spawnSync('bash', [join(dir, 'script.sh')], {encoding: 'utf8', env: {PATH: `${bin}:${process.env.PATH}`,
      CALLS: join(dir, 'calls'), SEEN: seen, ANSWERS: join(dir, 'answers'), SOURCE: repo,
      PREVIOUS_COMMIT_RESULT: join(dir, 'previous'), ...Object.fromEntries(Object.entries(env).map(([k, v]) => [k, fill(v)]))}});
    const read = file => { try { return readFileSync(file, 'utf8'); } catch { return ''; } };
    const bodies = readdirSync(seen).filter(f => f.startsWith('body-')).sort().map(f => JSON.parse(read(join(seen, f))));
    return {status: result.status, stdout: result.stdout, stderr: result.stderr, calls: read(join(dir, 'calls')), auth: read(join(seen, 'auth')), headerFiles: read(join(seen, 'header-files')),
      requests: read(join(seen, 'requests')).split('\n').filter(Boolean), bodies, previous: read(join(dir, 'previous')), shas};
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
}

const TOKEN = 'forgejo-token-that-travels-only-on-standard-input';
const FORGEJO = {FORGEJO_TOKEN: TOKEN, FORGEJO_API: 'http://forgejo-http.forgejo.svc:3000/api/v1', REPOSITORY: 'owner/shop'};
const setStatus = readFileSync(`${FILES}/forgejo-set-status.sh`, 'utf8');
const createRelease = readFileSync(`${FILES}/forgejo-create-release.sh`, 'utf8');
const updatePlane = readFileSync(`${FILES}/plane-update-status.sh`, 'utf8');

test('the commit status is pending, then success on Succeeded or Completed and failure on Failed, with the token only on the standard input of curl', () => {
  const RUN_URL = 'https://tekton.example.invalid/#/namespaces/forgejo-build/pipelineruns/forgejo-release-abc12';
  for (const [runState, state] of [['pending', 'pending'], ['Succeeded', 'success'], ['Completed', 'success'], ['Failed', 'failure']]) {
    const run = execute(setStatus, {...FORGEJO, COMMIT: SHA, RUN_URL, RUN_STATE: runState}, [`POST /statuses/${SHA} 201 {}`]);
    assert.equal(run.status, 0, run.stderr);
    assert.deepEqual(run.requests, [`POST http://forgejo-http.forgejo.svc:3000/api/v1/repos/owner/shop/statuses/${SHA}`]);
    assert.deepEqual(run.bodies, [{state, target_url: RUN_URL, description: run.bodies[0].description, context: 'tekton/forgejo-release'}]);
    assert.equal(run.auth, `Authorization: token ${TOKEN}\n`);
    assert.equal(run.headerFiles, '');
    assert.ok(!run.calls.includes(TOKEN) && !run.stdout.includes(TOKEN) && !run.stderr.includes(TOKEN));
  }
  const unknown = execute(setStatus, {...FORGEJO, COMMIT: SHA, RUN_URL, RUN_STATE: 'None'}, [`POST /statuses/${SHA} 201 {}`]);
  assert.notEqual(unknown.status, 0, 'PLANTED DEFECT: a state that is no outcome sets nothing');
  assert.deepEqual(unknown.requests, []);
  const refused = execute(setStatus, {...FORGEJO, COMMIT: SHA, RUN_URL, RUN_STATE: 'pending'}, [`POST /statuses/${SHA} 403 {"message":"forbidden"}`]);
  assert.notEqual(refused.status, 0, 'PLANTED DEFECT: a refused status fails the task');
  assert.match(refused.stderr, /HTTP 403/);
});

test('the release lists the commits since the nearest earlier tag and hands that tag\'s commit on', () => {
  const commits = ['first SHOP-1', 'second SHOP-2', 'third SHOP-3'];
  const tags = '[{"name":"v0.0.1","commit":{"sha":"${SHA0}"}},{"name":"v0.0.0","commit":{"sha":"${SHA0}"}},{"name":"elsewhere","commit":{"sha":"ffffffffffffffffffffffffffffffffffffffff"}},{"name":"v0.0.2","commit":{"sha":"${SHA2}"}}]';
  const run = execute(createRelease, {...FORGEJO, TAG: 'v0.0.2'}, [`GET /tags?limit=50 200 ${tags}`, 'POST /releases 201 {}'], commits);
  assert.equal(run.status, 0, run.stderr);
  assert.equal(run.previous, run.shas[0]);
  assert.equal(run.auth, `Authorization: token ${TOKEN}\n`);
  assert.equal(run.headerFiles, '');
  assert.equal(run.bodies.length, 1);
  assert.equal(run.bodies[0].tag_name, 'v0.0.2');
  assert.deepEqual(run.bodies[0].body.split('\n').filter(Boolean).map(line => line.replace(/ \([0-9a-f]+\)$/, '')), ['- third SHOP-3', '- second SHOP-2']);
  assert.ok(!run.calls.includes(TOKEN));

  const first = execute(createRelease, {...FORGEJO, TAG: 'v0.0.1'}, ['GET /tags?limit=50 200 [{"name":"v0.0.1","commit":{"sha":"${SHA1}"}}]', 'POST /releases 201 {}'], commits.slice(0, 2));
  assert.equal(first.status, 0, first.stderr);
  assert.equal(first.previous, '', 'the first tag has no tag before it');
  assert.equal(first.bodies[0].body.split('\n').filter(Boolean).length, 2);

  const taken = execute(createRelease, {...FORGEJO, TAG: 'v0.0.1'}, ['GET /tags?limit=50 200 []', 'POST /releases 409 {"message":"exists"}'], commits.slice(0, 1));
  assert.notEqual(taken.status, 0, 'PLANTED DEFECT: a release Forgejo refuses fails the task');
});

const PLANE_TARGETS = {workspace: 'simplidigita', projects: [
  {prefixes: ['ansiwise-'], id: 'e5c01046-3739-4af7-abc4-3c13b28dd232', identifier: 'ANSIWISE'},
  {prefixes: ['hostyour-'], id: '7bbca0da-56a0-4c33-bf6d-aaef3eb327d1', identifier: 'HOSTYOUR'},
  {prefixes: ['simplidigita-', 'digita-'], id: '252cf88e-3c7d-4b13-a444-13403ddcb976', identifier: 'SIMPL'},
]};
const PLANE = {PLANE_TOKEN: 'plane-token-on-standard-input', PLANE_API: 'http://plane-api.plane.svc:8000/api/v1',
  PLANE_TARGETS: JSON.stringify({...PLANE_TARGETS, projects: PLANE_TARGETS.projects.map(({identifier, ...target}) => target)}),
  REPOSITORY: 'ansiwise-owner/hostyour-release-test', TAG: 'v0.0.2', PREVIOUS_COMMIT: '${SHA0}'};
const PLANE_COMMITS = ['first HOSTYOUR-1', 'fix HOSTYOUR-2 and (HOSTYOUR-3)', 'not XHOSTYOUR-4 nor HOSTYOUR-5x, again HOSTYOUR-2'];
function planeAnswers(target = PLANE_TARGETS.projects[1], missing = false) {
  return [`GET /projects/${target.id}/ 200 {"identifier":"${target.identifier}"}`,
    'GET /states/?per_page=100 200 {"next_page_results":false,"results":[{"id":"todo","name":"Todo","group":"unstarted"},{"id":"wrong","name":"Released","group":"started"},{"id":"done","name":"Released","group":"completed"}]}',
    ...[2, 3].flatMap(n => [`GET /work-items/${target.identifier}-${n}/ 200 {"id":"item-${n}","project":"${target.id}"}`, `PATCH /work-items/item-${n}/ 200 {}`]),
    `GET /modules/?per_page=100 200 {"next_page_results":false,"results":${missing ? '[]' : '[{"id":"m1","name":"v0.0.1"},{"id":"m2","name":"v0.0.2"}]'}}`,
    'POST /modules/ 201 {"id":"m2","name":"v0.0.2"}',
    'POST /modules/m2/module-issues/ 200 [{"module":"m2","issue":"item-2"},{"module":"m2","issue":"item-3"}]',
    'PATCH /modules/m2/ 200 {"id":"m2","status":"completed"}'];
}
function assertPlaneRelease(run, target, missing) {
  assert.equal(run.status, 0, run.stderr);
  const project = `${PLANE.PLANE_API}/workspaces/simplidigita/projects/${target.id}`;
  assert.deepEqual(run.requests, [`GET ${project}/`, `GET ${project}/states/?per_page=100`,
    ...[2, 3].map(n => `GET ${PLANE.PLANE_API}/workspaces/simplidigita/work-items/${target.identifier}-${n}/`),
    `GET ${project}/modules/?per_page=100`, ...(missing ? [`POST ${project}/modules/`] : []),
    ...[2, 3].map(n => `PATCH ${project}/work-items/item-${n}/`),
    `POST ${project}/modules/m2/module-issues/`, `PATCH ${project}/modules/m2/`]);
  assert.deepEqual(run.bodies, [...(missing ? [{name: PLANE.TAG}] : []), {state: 'done'}, {state: 'done'},
    {issues: ['item-2', 'item-3']}, {status: 'completed'}]);
  assert.match(run.stdout, /module v0.0.2 is completed, 2 work items/);
  assert.equal(run.auth, 'X-API-Key: plane-token-on-standard-input\n');
  assert.equal(run.headerFiles, '');
  assert.ok(![run.calls, run.stdout, run.stderr].some(text => text.includes(PLANE.PLANE_TOKEN)));
}

test('the stand-in curl tells a token header file from a header on standard input', () => {
  const planted = execute('printf \'X-API-Key: %s\\n\' "$PLANE_TOKEN" > "$SOURCE/auth"; curl -sS -H "@$SOURCE/auth" -o /dev/null http://plane.invalid/x', PLANE);
  assert.notEqual(planted.headerFiles, '', 'PLANTED DEFECT: a token written to a header file is seen');
  const innocent = execute('printf \'X-API-Key: %s\\n\' "$PLANE_TOKEN" | curl -sS -H @- -o /dev/null http://plane.invalid/x', PLANE);
  assert.equal(innocent.headerFiles, '');
  assert.equal(innocent.auth, `X-API-Key: ${PLANE.PLANE_TOKEN}\n`);
});

test('Plane: every repository prefix selects only its configured project, creates a missing tag module or reuses it, attaches its work items and completes it', () => {
  for (const target of PLANE_TARGETS.projects) for (const prefix of target.prefixes) for (const missing of [false, true]) {
    const commits = PLANE_COMMITS.map(message => message.replaceAll('HOSTYOUR', target.identifier));
    const owner = prefix === 'hostyour-' ? 'ansiwise-innocent-owner' : 'hostyour-innocent-owner';
    const run = execute(updatePlane, {...PLANE, REPOSITORY: `${owner}/${prefix}release-test`}, planeAnswers(target, missing), commits);
    assertPlaneRelease(run, target, missing);
  }
});

test('Plane: an unmatched repository fails by name before any HTTP, regardless of the owner prefix', () => {
  const run = execute(updatePlane, {...PLANE, REPOSITORY: 'hostyour-owner/unmatched'}, [], PLANE_COMMITS);
  assert.notEqual(run.status, 0); assert.match(run.stderr, /unmatched/);
  assert.deepEqual(run.requests, []);
});

test('Plane: project IDs come from configuration, and the API supplies each identifier', () => {
  for (const [index, original] of PLANE_TARGETS.projects.entries()) {
    const target = {...original, id: `configured-${index}`, identifier: `API${index}`};
    const config = {workspace: 'simplidigita', projects: [{prefixes: target.prefixes, id: target.id}]};
    const run = execute(updatePlane, {...PLANE, REPOSITORY: `owner/${target.prefixes[0]}fixture`, PLANE_TARGETS: JSON.stringify(config)},
      planeAnswers(target), PLANE_COMMITS.map(message => message.replaceAll('HOSTYOUR', target.identifier)));
    assertPlaneRelease(run, target, false);
  }
});

test('Plane: a tag module on a later page is reused, and a release with no commit keys completes without an empty attachment', () => {
  const responses = [...planeAnswers().filter(a => !a.startsWith('GET /modules/')),
    'GET /modules/?per_page=100 200 {"next_page_results":true,"next_cursor":"100:1:0","results":[{"id":"m1","name":"v0.0.1"}]}',
    'GET /modules/?per_page=100&cursor=100%3A1%3A0 200 {"next_page_results":false,"results":[{"id":"m2","name":"v0.0.2"}]}'];
  const run = execute(updatePlane, PLANE, responses, PLANE_COMMITS);
  assert.equal(run.status, 0, run.stderr);
  assert.ok(run.requests.some(r => r.endsWith('cursor=100%3A1%3A0')));
  assert.ok(!run.requests.some(r => r.startsWith('POST') && r.endsWith('/modules/')));
  assert.deepEqual(run.bodies, [{state: 'done'}, {state: 'done'}, {issues: ['item-2', 'item-3']}, {status: 'completed'}]);
  const noKeys = execute(updatePlane, {...PLANE, PREVIOUS_COMMIT: ''}, planeAnswers(), ['an innocent message with no work item']);
  assert.equal(noKeys.status, 0, noKeys.stderr);
  assert.deepEqual(noKeys.bodies, [{status: 'completed'}]);
  assert.doesNotMatch(noKeys.requests.join('\n'), /module-issues/);
  assert.match(noKeys.stdout, /0 work items/);
});

test('PLANTED DEFECT: no Released in Completed, an unknown key and refused module creation or attachment never report completion', () => {
  const answers = planeAnswers();
  const replace = (prefix, replacement) => [...answers.filter(a => !a.startsWith(prefix)), replacement];
  const cases = [
    [replace('GET /states/', 'GET /states/?per_page=100 200 {"next_page_results":false,"results":[]}'), /no state Released/],
    [replace('GET /states/', 'GET /states/?per_page=100 200 {"next_page_results":false,"results":[{"id":"wrong","name":"Released","group":"started"}]}'), /no state Released/],
    [answers.filter(a => !a.startsWith('GET /work-items/HOSTYOUR-3/')), /HTTP 404/],
    [[...planeAnswers(undefined, true).filter(a => !a.startsWith('POST /modules/ ')), 'POST /modules/ 403 {"error":"forbidden"}'], /HTTP 403/],
    [replace('POST /modules/m2/module-issues/', 'POST /modules/m2/module-issues/ 403 {"error":"forbidden"}'), /HTTP 403/],
    [replace('POST /modules/m2/module-issues/', 'POST /modules/m2/module-issues/ 200 []'), /attach/],
    [replace('PATCH /work-items/item-2/', 'PATCH /work-items/item-2/ 403 {"error":"forbidden"}'), /HTTP 403/],
    [replace('GET /work-items/HOSTYOUR-3/', 'GET /work-items/HOSTYOUR-3/ 200 {"id":"item-3","project":"another-project"}'), /project/],
    [[...planeAnswers(undefined, true).filter(a => !a.startsWith('POST /modules/ ')), 'POST /modules/ 201 {}'], /no created module/],
  ];
  for (const [responses, message] of cases) {
    const run = execute(updatePlane, PLANE, responses, PLANE_COMMITS);
    assert.notEqual(run.status, 0); assert.match(run.stderr, message);
    assert.ok(!run.requests.some(r => r.startsWith('PATCH') && r.endsWith('/modules/m2/')));
    assert.doesNotMatch(run.stdout, /is completed/);
  }
  // A key read without its boundaries takes XHOSTYOUR-4 and HOSTYOUR-5x for keys of the project.
  const loose = updatePlane.replace('grep -E "^${identifier}-[0-9]+$"', 'grep -oE "${identifier}-[0-9]+"').replace("tr -c 'A-Za-z0-9_-' '\\n' <", 'cat');
  assert.notEqual(loose, updatePlane);
  assert.notEqual(execute(loose, PLANE, answers, PLANE_COMMITS).status, 0);
  assertPlaneRelease(execute(updatePlane, PLANE, answers, PLANE_COMMITS), PLANE_TARGETS.projects[1], false);
});

test('Plane: completion refusal and error bodies never become a successful report or disclose a credential', () => {
  for (const answer of ['PATCH /modules/m2/ 503 {"error":"plane-token-in-a-header-file"}', 'PATCH /modules/m2/ 200 {"id":"m2","status":"planned"}']) {
    const run = execute(updatePlane, PLANE, [...planeAnswers().filter(a => !a.startsWith('PATCH /modules/m2/')), answer], PLANE_COMMITS);
    assert.notEqual(run.status, 0);
    assert.doesNotMatch(run.stdout, /is completed/);
    assert.ok(![run.calls, run.stdout, run.stderr].some(text => text.includes(PLANE.PLANE_TOKEN)));
  }
  const leaked = updatePlane.replace('set -euo pipefail', 'set -euo pipefail\nprintf "%s\\n" "$PLANE_TOKEN"');
  assert.notEqual(leaked, updatePlane);
  assert.throws(() => assertPlaneRelease(execute(leaked, PLANE, planeAnswers(), PLANE_COMMITS), PLANE_TARGETS.projects[1], false),
    'PLANTED DEFECT: the output assertion must reject a credential leak');
  const innocent = updatePlane.replace('set -euo pipefail', 'set -euo pipefail\nprintf "Plane target configuration loaded\\n"');
  assertPlaneRelease(execute(innocent, PLANE, planeAnswers(), PLANE_COMMITS), PLANE_TARGETS.projects[1], false);
});

// ── The rendered charts ──────────────────────────────────────────────────────────────────────────
const build = renderChart('forgejo-build', ['--namespace', 'forgejo-build']);
const builder = renderChart('image-builder');
const byKind = (docs, kind, name) => docs.find(d => d.kind === kind && d.metadata.name === name);
// renderChart renders the prod stage, whose entries stand under prod/.
const STAGE = 'prod';
const API_TASKS = ['forgejo-set-status', 'forgejo-create-release', 'plane-update-status'];

/** Every way the run namespace breaks the rules above, named. */
function namespaceFindings(docs) {
  const found = [];
  const labels = byKind(docs, 'Namespace', 'forgejo-build')?.metadata.labels ?? {};
  const want = {'hostyour.cloud/workload': 'true', 'pod-security.kubernetes.io/enforce': 'privileged', 'pod-security.kubernetes.io/warn': 'baseline', 'pod-security.kubernetes.io/audit': 'baseline'};
  for (const [key, value] of Object.entries(want)) if (labels[key] !== value) found.push(`the namespace carries ${key}=${labels[key]}`);
  if ('hostyour.cloud/build' in labels) found.push('the namespace carries hostyour.cloud/build, which the release queue and the ci keeper select');
  if (byKind(docs, 'ServiceAccount', 'pipeline-sa')?.automountServiceAccountToken !== false) found.push('pipeline-sa mounts a token');
  const role = byKind(docs, 'Role', 'eventlistener-create-pipelineruns');
  if (JSON.stringify(role?.rules) !== JSON.stringify([{apiGroups: ['tekton.dev'], resources: ['pipelineruns'], verbs: ['create']}])) found.push(`the EventListener may ${JSON.stringify(role?.rules)}`);
  const subjects = byKind(docs, 'RoleBinding', 'eventlistener-create-pipelineruns')?.subjects;
  if (JSON.stringify(subjects) !== JSON.stringify([{kind: 'ServiceAccount', name: 'eventlistener-sa', namespace: 'image-builder'}])) found.push(`the grant goes to ${JSON.stringify(subjects)}`);
  for (const name of ['forgejo-build-tokens', 'forgejo-build-git']) {
    const secret = byKind(docs, 'ExternalSecret', name);
    if (secret?.spec.target.deletionPolicy !== 'Delete') found.push(`${name} turns a missing entry into an error, which holds up the waves`);
    if (!secret || secret.spec.data.some(d => d.remoteRef.key !== `${STAGE}/app/forgejo-build`)) found.push(`${name} reads beyond ${STAGE}/app/forgejo-build`);
    const expected = name === 'forgejo-build-tokens' ? ['forgejo-api-token', 'plane-api-token'] : ['forgejo-api-token', 'forgejo-user'];
    if (JSON.stringify(secret?.spec.data.map(d => d.remoteRef.property).sort()) !== JSON.stringify(expected)) found.push(`${name} reads fields beyond its credentials`);
  }
  return found;
}

/** Every way the Pipeline breaks the rules above, named. */
function pipelineFindings(docs) {
  const found = [];
  const pipeline = byKind(docs, 'Pipeline', 'forgejo-release');
  if (!pipeline) return ['no Pipeline forgejo-release'];
  const tasks = [...pipeline.spec.tasks, ...pipeline.spec.finally];
  const taskName = t => t.taskRef?.params?.find(p => p.name === 'name')?.value ?? `inline ${t.name}`;
  for (const task of tasks) {
    const holdsTokens = (task.params ?? []).some(p => p.value === 'forgejo-build-tokens');
    if (holdsTokens !== API_TASKS.includes(taskName(task))) found.push(`${task.name} (${taskName(task)}) ${holdsTokens ? 'holds' : 'lacks'} the API tokens`);
    if (task.taskRef && task.taskRef.params.find(p => p.name === 'namespace')?.value !== 'image-builder') found.push(`${task.name} resolves its Task outside image-builder`);
  }
  const clone = tasks.find(t => taskName(t) === 'git-clone');
  const param = (task, name) => task?.params.find(p => p.name === name)?.value;
  if (param(clone, 'credentials-secret') !== 'forgejo-build-git') found.push(`the clone reads ${param(clone, 'credentials-secret')}`);
  if (param(clone, 'url') !== 'http://forgejo-http.forgejo.svc:3000/$(params.repository).git') found.push(`the clone reads ${param(clone, 'url')}`);
  const plane = tasks.find(t => t.name === 'plane');
  if (param(plane, 'repository') !== '$(params.repository)') found.push('Plane has no repository selector');
  const targets = {...PLANE_TARGETS, projects: PLANE_TARGETS.projects.map(({identifier, ...target}) => target)};
  try { assert.deepEqual(JSON.parse(param(plane, 'plane-targets')), targets); }
  catch { found.push('Plane targets do not come from the pipeline values'); }
  for (const name of ['release', 'plane']) {
    const task = tasks.find(t => t.name === name);
    if (JSON.stringify(task?.when) !== JSON.stringify([{input: '$(params.event)', operator: 'in', values: ['tag']}])) found.push(`${name} runs on more than a tag`);
  }
  const build = tasks.find(t => taskName(t) === 'buildah-build-push');
  if (!build?.runAfter?.includes('check')) found.push('the build runs before its inputs are checked');
  const status = pipeline.spec.finally.find(t => taskName(t) === 'forgejo-set-status');
  if (param(status, 'state') !== '$(tasks.status)') found.push('no finally task sets the outcome');
  return found;
}

test('forgejo-build holds the run namespace, its one grant and the credentials a missing entry does not turn into an error', () => {
  assert.deepEqual(namespaceFindings(build), []);
});

test('forgejo-release hands the API tokens to the three API Tasks alone and releases on a tag only', () => {
  assert.deepEqual(pipelineFindings(build), []);
});

test('Plane Task reads its target configuration and repository as parameters, and only its API token from a Secret', () => {
  const task = byKind(builder, 'Task', 'plane-update-status');
  const env = task.spec.steps[0].env;
  assert.deepEqual(env.filter(e => e.valueFrom).map(e => e.valueFrom.secretKeyRef.key), ['plane-api-token']);
  for (const [name, param] of [['REPOSITORY', 'repository'], ['PLANE_TARGETS', 'plane-targets']]) {
    assert.equal(env.find(e => e.name === name)?.value, `$(params.${param})`);
    assert.ok(task.spec.params.some(p => p.name === param && p.type === 'string'));
  }
});

test('PLANTED DEFECT: the build label, a token mount, a wider grant, a token in the build, a release on a pull request are each found', () => {
  const plant = (docs, kind, name, edit) => { const copy = structuredClone(docs); edit(byKind(copy, kind, name)); return copy; };
  assert.notDeepEqual(namespaceFindings(plant(build, 'Namespace', 'forgejo-build', ns => { ns.metadata.labels['hostyour.cloud/build'] = 'true'; })), []);
  assert.notDeepEqual(namespaceFindings(plant(build, 'ServiceAccount', 'pipeline-sa', sa => { delete sa.automountServiceAccountToken; })), []);
  assert.notDeepEqual(namespaceFindings(plant(build, 'Role', 'eventlistener-create-pipelineruns', r => { r.rules[0].verbs.push('delete'); })), []);
  assert.notDeepEqual(namespaceFindings(plant(build, 'ExternalSecret', 'forgejo-build-tokens', s => { delete s.spec.target.deletionPolicy; })), []);
  assert.notDeepEqual(namespaceFindings(plant(build, 'ExternalSecret', 'forgejo-build-tokens', s => { s.spec.data.push({remoteRef: {key: `${STAGE}/app/forgejo-build`, property: 'plane-project'}}); })), []);
  assert.notDeepEqual(pipelineFindings(plant(build, 'Pipeline', 'forgejo-release', p => {
    p.spec.tasks.find(t => t.name === 'plane').params = p.spec.tasks.find(t => t.name === 'plane').params.filter(p => p.name !== 'repository'); })), []);
  assert.notDeepEqual(pipelineFindings(plant(build, 'Pipeline', 'forgejo-release', p => {
    p.spec.tasks.find(t => t.name === 'build').params.push({name: 'tokens-secret', value: 'forgejo-build-tokens'}); })), []);
  assert.notDeepEqual(pipelineFindings(plant(build, 'Pipeline', 'forgejo-release', p => { delete p.spec.tasks.find(t => t.name === 'release').when; })), []);
});

// ── The deliveries ───────────────────────────────────────────────────────────────────────────────
// Each Trigger's secretRef names a Secret and a key; each Secret is an ExternalSecret over a Vault
// property. A delivery passes a Trigger's github interceptor when it is signed with the value the
// Trigger reads, so the value stands in as the Vault path and property it comes from.
function keyOf(docs, secretRef) {
  const secret = docs.find(d => d.kind === 'ExternalSecret' && d.spec.target.name === secretRef.secretName);
  const data = secret?.spec.data.find(d => d.secretKey === secretRef.secretKey);
  return data ? `${data.remoteRef.key}:${data.remoteRef.property}` : `unread ${secretRef.secretName}/${secretRef.secretKey}`;
}
const sign = (key, body) => `sha256=${createHmac('sha256', key).update(body).digest('hex')}`;
/** The Triggers whose interceptor admits a delivery signed with `key`. */
function admitting(docs, key) {
  const body = '{"ref":"refs/tags/v0.0.1"}';
  return docs.filter(d => d.kind === 'Trigger').filter(trigger => {
    const ref = trigger.spec.interceptors.find(i => i.ref.name === 'github').params.find(p => p.name === 'secretRef').value;
    return sign(keyOf(docs, ref), body) === sign(key, body);
  }).map(t => t.metadata.name).sort();
}
const FORGEJO_KEY = `${STAGE}/app/forgejo-webhook:forgejo-webhook-secret`;
const GITHUB_KEY = `${STAGE}/app/image-builder:github-webhook-secret`;

test('a Forgejo delivery passes the Forgejo Triggers alone, and a GitHub delivery the GitHub Triggers alone', () => {
  assert.deepEqual(admitting(builder, FORGEJO_KEY), ['forgejo-pull-request', 'forgejo-tag-push']);
  assert.deepEqual(admitting(builder, GITHUB_KEY), ['github-ci-push', 'github-deploy-request', 'github-release-publish']);
  const webhook = byKind(builder, 'ExternalSecret', 'image-builder-forgejo-webhook-secret');
  assert.equal(webhook.spec.target.deletionPolicy, 'Delete', 'a missing key leaves image-builder Healthy and refuses every Forgejo delivery');
});

test('PLANTED DEFECT: a Forgejo Trigger on GitHub\'s key, or the Forgejo key beside GitHub\'s, crosses the two', () => {
  const crossed = structuredClone(builder);
  byKind(crossed, 'Trigger', 'forgejo-tag-push').spec.interceptors[0].params[0].value = {secretName: 'image-builder-webhook-secrets', secretKey: 'github'};
  assert.deepEqual(admitting(crossed, GITHUB_KEY), ['forgejo-tag-push', 'github-ci-push', 'github-deploy-request', 'github-release-publish']);
  const shared = structuredClone(builder);
  byKind(shared, 'ExternalSecret', 'image-builder-forgejo-webhook-secret').spec.data[0].remoteRef = {key: `${STAGE}/app/image-builder`, property: 'github-webhook-secret'};
  assert.equal(admitting(shared, FORGEJO_KEY).length, 0);
  assert.equal(admitting(shared, GITHUB_KEY).length, 5);
});

const evaluate = (policy, requests) => execFileSync('go', ['run', '.'], {cwd: 'scripts/vap-eval', encoding: 'utf8',
  input: JSON.stringify({policy, requests})}).split('\n').filter(Boolean).map(line => JSON.parse(line));
const celOf = name => {
  const cel = byKind(builder, 'Trigger', name).spec.interceptors.find(i => i.ref.name === 'cel').params;
  return {spec: {variables: cel.find(p => p.name === 'overlays').value.map(o => ({name: o.key, expression: o.expression})),
    validations: [{expression: cel.find(p => p.name === 'filter').value, message: 'ignored'}]}};
};
const repository = {name: 'Shop', full_name: 'Owner/Shop'};

test('a tag push and an opened or updated pull request start a run; a branch, a deleted tag, a closed pull request do not', () => {
  const tags = evaluate(celOf('forgejo-tag-push'), [
    {body: {ref: 'refs/tags/v0.0.1', after: SHA, repository}},
    {body: {ref: 'refs/heads/main', after: SHA, repository}},
    {body: {ref: 'refs/tags/v0.0.1', after: '0'.repeat(40), repository}},
    {body: {ref: 'refs/tags/a/b', after: SHA, repository}}]);
  assert.deepEqual(tags.map(v => v.denied.length === 0), [true, false, false, false]);
  assert.deepEqual(tags[0].variables, {repository: 'Owner/Shop', 'image-name': 'forgejo/owner/shop', commit: SHA, revision: 'refs/tags/v0.0.1', tag: 'v0.0.1'});
  const pulls = evaluate(celOf('forgejo-pull-request'), ['opened', 'synchronized', 'reopened', 'closed'].map(action =>
    ({body: {action, number: 7, pull_request: {head: {sha: SHA}}, repository}})));
  assert.deepEqual(pulls.map(v => v.denied.length === 0), [true, true, true, false]);
  assert.deepEqual(pulls[0].variables, {repository: 'Owner/Shop', 'image-name': 'forgejo/owner/shop', commit: SHA, revision: 'refs/pull/7/head'});
});

test('the run a delivery creates passes the PipelineRun guard in forgejo-build, carries no label of the queue or the keeper, and a foreign run does not', () => {
  const template = byKind(builder, 'TriggerTemplate', 'forgejo-release');
  const run = JSON.parse(JSON.stringify(template.spec.resourcetemplates[0]).replace(/\$\(tt\.params\.[a-z-]+\)/g, 'x'));
  assert.equal(run.metadata.namespace, 'forgejo-build');
  assert.ok(!Object.keys(run.metadata.labels ?? {}).some(k => k.startsWith('image-builder.io/')), 'the release queue and the ci keeper never select it');
  const binding = builder.find(d => d.kind === 'ValidatingAdmissionPolicyBinding' && d.spec.matchResources.namespaceSelector.matchLabels?.['kubernetes.io/metadata.name'] === 'forgejo-build');
  assert.equal(binding?.spec.policyName, 'image-builder-pipelinerun-guard');
  assert.deepEqual(binding.spec.validationActions, ['Deny', 'Audit']);
  const guard = byKind(builder, 'ValidatingAdmissionPolicy', 'image-builder-pipelinerun-guard');
  const request = object => ({object, oldObject: null, request: {operation: 'CREATE', namespace: 'forgejo-build', userInfo: {username: 'system:serviceaccount:image-builder:eventlistener-sa'}}});
  const verdicts = evaluate(guard, [run,
    {...run, spec: {...run.spec, pipelineRef: {name: 'shop-release'}}},
    {...run, spec: {...run.spec, taskRunTemplate: {serviceAccountName: 'default'}}}].map(request));
  assert.deepEqual(verdicts[0].denied, [], 'PLANTED INNOCENT: the run as the template creates it');
  assert.notDeepEqual(verdicts[1].denied, [], 'PLANTED DEFECT: another namespace\'s Pipeline');
  assert.notDeepEqual(verdicts[2].denied, [], 'PLANTED DEFECT: another ServiceAccount');
});
