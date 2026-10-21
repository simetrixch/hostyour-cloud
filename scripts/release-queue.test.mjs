import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync, spawn} from 'node:child_process';
import {existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {createServer} from 'node:http';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

// The release queue runs up to nine release or publish PipelineRuns at a time on the build plane, one per unit. Its
// decision is the jq program in clusters/inventories/image-builder/files, run here on planted PipelineRuns;
// the charts are rendered for the pieces that make it work: runs created waiting, the CronJob, and its rights.

const QUEUE = 'clusters/inventories/image-builder/files/release-queue.jq';
// releaseQueue.maxRunning of clusters/inventories/image-builder, which the render test below holds to this.
const MAX = 9;
// The build namespaces of MAX + 1 units: MAX of them fill the queue, and the one after them waits.
const NAMESPACES = Array.from({length: MAX + 1}, (_, i) => `unit${i}-build`);
// What a run that waits notes: the release (namespace and tag) of each run it waits for, in the order given.
const releasesOf = (runs, suffix = '') => runs.map((r) => `${r.metadata.namespace}/${r.spec.params[0].value}${suffix}`).join(' and ');

let clock = 0;
// A release run carries image-builder.io/consumer and a publish run image-builder.io/publish, as their
// TriggerTemplates and Pipelines give them; a run of any other pipeline carries neither.
const labelOf = (pipeline) => (pipeline.endsWith('-release') ? {'image-builder.io/consumer': 'x'}
  : pipeline.endsWith('-publish') ? {'image-builder.io/publish': 'x'} : {});
const run = (ns, tag, {pending = false, succeeded, pipeline = ns.replace(/-build$/, '-release'), behind, labels = labelOf(pipeline)} = {}) => ({
  metadata: {namespace: ns, name: `${tag}-${++clock}`, creationTimestamp: new Date(Date.UTC(2026, 9, 8, 5) + clock * 60000).toISOString().replace('.000Z', 'Z'), labels,
    ...(behind ? {annotations: {'image-builder.io/queued-behind': behind}} : {})},
  spec: {pipelineRef: {name: pipeline}, params: [{name: 'release-tag', value: tag}], ...(pending ? {status: 'PipelineRunPending'} : {})},
  status: succeeded === undefined ? {} : {conditions: [{type: 'Succeeded', status: succeeded}]},
});

const decideWith = (program, items, max = MAX) => execFileSync('jq', ['-c', '--argjson', 'max', String(max), '-f', program], {input: JSON.stringify({items}), encoding: 'utf8'})
  .split('\n').filter(Boolean).map((line) => JSON.parse(line));
const decide = (items, max = MAX) => decideWith(QUEUE, items, max);
const started = (changes) => changes.filter((c) => c.type === 'json').map((c) => c.name);
const waiting = (changes) => changes.filter((c) => c.type === 'merge')
  .map((c) => [c.name, c.patch.metadata.annotations['image-builder.io/queued-behind']]);
// The real queue with one piece of its text changed, to show a test goes red on the defect that change plants.
const planted = (from, to, items, max = MAX) => {
  const dir = mkdtempSync(join(tmpdir(), 'release-queue-'));
  try {
    const program = join(dir, 'release-queue.jq'), text = readFileSync(QUEUE, 'utf8');
    assert.ok(text.includes(from), `the queue carries ${from}`);
    writeFileSync(program, text.replace(from, to));
    return decideWith(program, items, max);
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
};

test('with nothing running, the oldest stage run of a release starts and the other stage runs of it wait', () => {
  const a1 = run('shop-build', 'a', {pending: true}), a2 = run('shop-build', 'a', {pending: true});
  const changes = decide([a2, a1]);
  assert.deepEqual(started(changes), [a1.metadata.name], 'the oldest run of the release starts alone');
  assert.deepEqual(waiting(changes), [[a2.metadata.name, 'shop-build/a']], 'the second stage waits for the first although slots are free');
  assert.deepEqual(changes.find((c) => c.name === a1.metadata.name).patch, [{op: 'remove', path: '/spec/status'}]);
  assert.equal(started(planted('(.holder | has($unit)) or', 'false or', [a2, a1])).length, 2, 'PLANTED DEFECT: a queue that admits a run of a release that is open starts both stages');
});

test('nine units start, the tenth waits', () => {
  const runs = NAMESPACES.map((ns, i) => run(ns, `t${i}`, {pending: true})), oldest = runs.slice(0, MAX), tenth = runs[MAX];
  const changes = decide([...runs].reverse());
  assert.deepEqual(started(changes).sort(), oldest.map((r) => r.metadata.name).sort(), 'the nine oldest start');
  assert.deepEqual(waiting(changes), [[tenth.metadata.name, releasesOf(oldest)]], 'the tenth notes the nine it waits for');
  assert.deepEqual(changes.map((x) => x.say).filter((say) => say.includes(' waits ')),
    [`${tenth.metadata.namespace}/${tenth.metadata.name} (release ${tenth.metadata.namespace}/t${MAX}) waits for release ${releasesOf(oldest)}`]);
  assert.deepEqual(started(decide([...runs].reverse(), MAX - 1)).length, MAX - 1, 'PLANTED DEFECT: any limit below nine holds a ninth unit back');
  assert.equal(started(decide([...runs].reverse(), MAX + 1)).length, MAX + 1, 'PLANTED INNOCENT: a queue told to run ten starts all ten');
});

test('runs that already run take their slots, and the next waits', () => {
  const runs = NAMESPACES.map((ns, i) => run(ns, `t${i}`, {pending: i > 0})), running = runs[0], tenth = runs[MAX];
  const changes = decide(runs);
  assert.deepEqual(started(changes), runs.slice(1, MAX).map((r) => r.metadata.name), 'eight more start beside the running one');
  assert.deepEqual(waiting(changes), [[tenth.metadata.name, releasesOf([running, ...runs.slice(1, MAX)])]]);
});

test('every run counts as a slot, so stage runs of one tag that run already hold two slots', () => {
  const stages = [run(NAMESPACES[0], 'a'), run(NAMESPACES[0], 'a')], rest = NAMESPACES.slice(1, MAX - 1).map((ns, i) => run(ns, `t${i + 1}`));
  const next = run(NAMESPACES[MAX - 1], 'n', {pending: true});
  const changes = decide([...stages, ...rest, next]);
  assert.deepEqual(started(changes), [], 'nine runs run, whatever their tags: the tenth run waits');
  assert.deepEqual(waiting(changes), [[next.metadata.name, releasesOf([stages[0], ...rest])]]);
  assert.deepEqual(started(decide([...stages.slice(0, 1), ...rest, next])), [next.metadata.name], 'PLANTED INNOCENT: with one run of the tag eight run and the ninth starts');
  assert.deepEqual(started(planted('active: ($running | length)', 'active: ($running | map(releaseKey) | inOrder | length)', [...stages, ...rest, next])), [next.metadata.name],
    'PLANTED DEFECT: counting the keys of the running runs lets a tenth run start');
});

test('two of the same unit: one starts, one waits', () => {
  const a = run('shop-build', 'a', {pending: true}), b = run('shop-build', 'b', {pending: true});
  const changes = decide([b, a]);
  assert.deepEqual(started(changes), [a.metadata.name], 'the older release of the unit starts');
  assert.deepEqual(waiting(changes), [[b.metadata.name, 'shop-build/a']], 'the other waits for the release of its own unit, not for a free slot');
  const running = decide([run('shop-build', 'a'), run('shop-build', 'b', {pending: true})]);
  assert.deepEqual([started(running), waiting(running).map(([, behind]) => behind)], [[], ['shop-build/a']], 'a release that runs holds back the next release of its unit although a slot is free');
  assert.equal(started(planted('(.holder | has($unit)) or', 'false or', [b, a])).length, 2, 'PLANTED DEFECT: a queue that ignores the unit starts both');
  const other = run('post-build', 'b', {pending: true});
  assert.equal(started(decide([a, other])).length, 2, 'PLANTED INNOCENT: two releases of two units start together');
});

test('planted defect: nine runs that run hold every other release back', () => {
  const running = NAMESPACES.slice(0, MAX).map((ns, i) => run(ns, `t${i}`)), c = run(NAMESPACES[MAX], 'c', {pending: true});
  const changes = decide([...running, c]);
  assert.deepEqual(started(changes), []);
  assert.deepEqual(waiting(changes), [[c.metadata.name, releasesOf(running)]]);
});

test('the stage run of a release that runs waits for it, whether or not a slot is free', () => {
  const test_ = run('shop-build', 'a'), prod = run('shop-build', 'a', {pending: true});
  assert.deepEqual(started(decide([test_, prod])), [], 'a slot is free and the second stage still waits');
  assert.deepEqual(waiting(decide([test_, prod])), [[prod.metadata.name, 'shop-build/a']]);
  const next = run('auth-build', 'c', {pending: true});
  const full = [test_, run('post-build', 'b'), prod, next];
  assert.deepEqual(started(decide(full)), [next.metadata.name], 'the stage waits for its own unit and does not hold the slot back from another unit');
  assert.deepEqual(started(decide([run('shop-build', 'a', {succeeded: 'True'}), prod])), [prod.metadata.name], 'PLANTED INNOCENT: the second stage starts once the first has finished');
});

test('a retry of a tag waits for the run of the tag that runs, and a younger unit starts past an older run that waits for its own unit', () => {
  const running = run('shop-build', 'a'), retry = run('shop-build', 'a', {pending: true}), other = run('post-build', 'b', {pending: true});
  const changes = decide([running, retry, other]);
  assert.deepEqual(started(changes), [other.metadata.name]);
  assert.deepEqual(waiting(changes), [[retry.metadata.name, 'shop-build/a']]);
  const oldBlocked = run('shop-build', 'x', {pending: true}), youngerUnit = run('auth-build', 'y', {pending: true});
  assert.deepEqual(started(decide([running, oldBlocked, youngerUnit])), [youngerUnit.metadata.name], 'oldest first among the runs that can start');
});

test('planted innocent: finished runs, succeeded or failed, hold nothing back', () => {
  const b = run('post-build', 'b', {pending: true});
  const changes = decide([run('shop-build', 'a', {succeeded: 'True'}), run('auth-build', 'c', {succeeded: 'False'}), run('shop-build', 'd', {succeeded: 'True'}), b]);
  assert.deepEqual(started(changes), [b.metadata.name]);
});

test('runs of other pipelines neither hold a release back nor are touched', () => {
  const b = run('post-build', 'b', {pending: true});
  const changes = decide([run('shop-build', 't', {pipeline: 'shop-tests'}), run('shop-build', 'u', {pipeline: 'shop-tests', pending: true}), b]);
  assert.deepEqual(changes.map((c) => c.name), [b.metadata.name]);
});

test('a run that already notes what it waits for is not patched again, and its note goes when it starts', () => {
  const running = NAMESPACES.slice(0, MAX).map((ns, i) => run(ns, `t${i}`)), tenth = NAMESPACES[MAX];
  const note = releasesOf(running);
  const b = run(tenth, 'b', {pending: true, behind: note});
  assert.deepEqual(decide([...running, b]), []);
  const later = decide([run(NAMESPACES[0], 't0', {succeeded: 'True'}), ...running.slice(1), b]);
  assert.deepEqual(later[0].patch, [{op: 'remove', path: '/spec/status'}, {op: 'remove', path: '/metadata/annotations/image-builder.io~1queued-behind'}]);
  const moved = decide([...running.slice(0, MAX - 1), run(tenth, 'x'), run(tenth, 'b', {pending: true, behind: note})]);
  assert.deepEqual(waiting(moved).map(([, behind]) => behind), [`${tenth}/x`], 'a note that no longer says what the run waits for is written again');
});

function renderChart(chart, extra = []) {
  const rendered = execFileSync('helm', ['template', chart, 'clusters/inventories/' + chart,
    '--namespace', chart === 'image-builder' ? 'image-builder' : 'argocd',
    '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
    '-f', 'clusters/inventories/' + chart + '/values-common.yaml',
    ...(existsSync('clusters/inventories/' + chart + '/values-prod.yaml') ?
      ['-f', 'clusters/inventories/' + chart + '/values-prod.yaml'] : []),
    '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/registration.yaml', ...extra],
    {encoding: 'utf8', maxBuffer: 8 * 1024 * 1024});
  return JSON.parse(execFileSync('yq', ['eval-all', '-o=json', '-I=0', '[.]', '-'],
    {input: rendered, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024})).filter(Boolean);
}

test('release runs are created waiting, and the queue runs every minute with read-only cluster rights', () => {
  const docs = renderChart('image-builder');
  const template = docs.find((d) => d.kind === 'TriggerTemplate' && d.metadata.name === 'deploy-request');
  assert.equal(template.spec.resourcetemplates[0].spec.status, 'PipelineRunPending');
  const cron = docs.find((d) => d.kind === 'CronJob' && d.metadata.name === 'release-queue');
  assert.equal(cron.spec.schedule, '* * * * *');
  assert.equal(cron.spec.jobTemplate.spec.template.spec.serviceAccountName, 'release-queue');
  assert.equal(cron.spec.jobTemplate.spec.template.spec.containers[0].env.find((e) => e.name === 'RELEASE_MAX_RUNNING')?.value, String(MAX),
    'the CronJob hands the queue the number of releases that run at once, which the decision tests above use');
  const read = docs.find((d) => d.kind === 'ClusterRole' && d.metadata.name === 'image-builder-release-queue-read');
  assert.deepEqual(read.rules, [{apiGroups: ['tekton.dev'], resources: ['pipelineruns'], verbs: ['get', 'list', 'watch']}]);
  const map = docs.find((d) => d.kind === 'ConfigMap' && d.metadata.name === 'release-queue');
  assert.ok(map.data['release-queue.jq'].includes('PipelineRunPending'));
  const guard = docs.find((d) => d.kind === 'ValidatingAdmissionPolicy' && d.metadata.name === 'image-builder-pipelinerun-guard');
  assert.ok(guard.spec.variables.find((v) => v.name === 'isReleaseQueue').expression.includes("'image-builder' + ':release-queue'"));
  assert.ok(guard.spec.validations.some((v) => v.expression.includes('variables.isReleaseQueue')));
});

test('the release queue carries the lister its script sources', () => {
  const docs = renderChart('image-builder');
  const lister = readFileSync('clusters/inventories/image-builder/files/list-pipelineruns.sh', 'utf8');
  const map = docs.find((d) => d.kind === 'ConfigMap' && d.metadata.name === 'release-queue');
  assert.equal(map?.data?.['list-pipelineruns.sh'], lister, 'the ConfigMap release-queue does not carry files/list-pipelineruns.sh, which release-queue.sh sources');
});

test('each build namespace grants the queue patch and delete on its PipelineRuns and nothing else', () => {
  const docs = renderChart('consumer-build', ['--set-json', 'unit=' + JSON.stringify({name: 'shop', repoURL: 'https://github.com/check/shop.git', buildsJson: '[]'})]);
  const role = docs.find((d) => d.kind === 'Role' && d.metadata.name === 'release-queue-start-and-prune-pipelineruns');
  assert.equal(role.metadata.namespace, 'shop-build');
  assert.deepEqual(role.rules, [{apiGroups: ['tekton.dev'], resources: ['pipelineruns'], verbs: ['patch', 'delete']}]);
  const binding = docs.find((d) => d.kind === 'RoleBinding' && d.metadata.name === 'release-queue-start-and-prune-pipelineruns');
  assert.deepEqual(binding.subjects, [{kind: 'ServiceAccount', name: 'release-queue', namespace: 'image-builder'}]);
});

const deleted = (changes) => changes.filter((c) => c.verb === 'delete').map((c) => c.name);
const finished = (ns, count, pipeline) => Array.from({length: count}, (_, i) => run(ns, `done${i}`, {succeeded: i % 2 ? 'True' : 'False', pipeline}));

test('a namespace keeps its newest 20 finished release runs, and a waiting or running release is never deleted', () => {
  const old = finished('shop-build', 21);
  const waitingRun = run('shop-build', 'next', {pending: true}), runningRun = run('shop-build', 'now');
  const changes = decide([...old, waitingRun, runningRun, ...finished('post-build', 20)]);
  assert.deepEqual(deleted(changes), [old[0].metadata.name], 'only the oldest of 21 finished runs goes; 20 in post-build stay');
  assert.equal(changes.at(-1).verb, 'delete', 'deletes come after every start and note');
  assert.deepEqual(waiting(changes), [[waitingRun.metadata.name, 'shop-build/now']], 'the waiting run stays, behind the running release of its unit');
});

test('planted defect: a queue that deletes by age alone, finished or not, is caught', () => {
  const dir = mkdtempSync(join(tmpdir(), 'release-queue-'));
  try {
    const byAge = join(dir, 'release-queue.jq');
    writeFileSync(byAge, readFileSync(QUEUE, 'utf8').replace('| ([.items[] | select(isQueued) | select(isDone)]', '| ([.items[] | select(isQueued)]'));
    const waitingRun = run('shop-build', 'next', {pending: true});
    const items = [...finished('shop-build', 20), waitingRun];
    const changes = decideWith(byAge, items);
    assert.notDeepEqual(deleted(changes), deleted(decide(items)), 'the planted queue deletes what the real one keeps');
    assert.deepEqual(deleted(decide(items)), [], 'PLANTED INNOCENT: 20 finished runs and a waiting one: nothing is deleted');
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
});

// A publish run (clusters/inventories/consumer-build pipeline-publish.yaml) packs and pushes a release's npm
// packages. It waits in the same queue under a key of its own and takes a slot like a release: up to nine releases or
// publish runs run at once, of different units, never two of one unit. The memory budget (releaseCapacity in consumer-build)
// bounds the sum of the limits of nine such runs, not the free memory of the node.
const publish = (ns, tag, options = {}) => run(ns, tag, {...options, pipeline: ns.replace(/-build$/, '-publish')});
test('a publish run waits behind a running release of its own unit, its own release included, and runs beside one of another unit', () => {
  const release = run('shop-build', 'a'), own = publish('shop-build', 'a', {pending: true});
  let changes = decide([release, own]);
  assert.deepEqual(started(changes), [], 'the publish run of a running release does not start beside it');
  assert.deepEqual(waiting(changes), [[own.metadata.name, 'shop-build/a']]);
  const first = publish('post-build', 'b', {pending: true}), second = run('post-build', 'b', {pending: true});
  changes = decide([second, first]);
  assert.deepEqual(started(changes), [first.metadata.name], 'the older publish run starts alone');
  assert.deepEqual(waiting(changes), [[second.metadata.name, 'post-build/b publish']], 'the release of the same tag waits for it');
  const other = run('shop-build', 'd', {pending: true}), sameUnit = run('auth-build', 'e', {pending: true});
  changes = decide([publish('auth-build', 'c'), other, sameUnit]);
  assert.deepEqual(started(changes), [other.metadata.name], 'a running publish run lets a release of another unit start');
  assert.deepEqual(waiting(changes), [[sameUnit.metadata.name, 'auth-build/c publish']], 'and holds back a release of its own unit');
});

test('publish runs take the slots of releases: nine publish runs fill the queue, and a mix fills it the same', () => {
  const units = NAMESPACES.slice(0, MAX), next = run(NAMESPACES[MAX], 'e', {pending: true});
  const publishing = units.map((ns, i) => publish(ns, `p${i}`));
  const full = decide([...publishing, next]);
  assert.deepEqual(started(full), [], 'nine publish runs run: no release starts');
  assert.deepEqual(waiting(full), [[next.metadata.name, releasesOf(publishing, ' publish')]]);
  const mixed = decide([...units.map((ns, i) => (i % 2 === 0 ? publish(ns, `p${i}`) : run(ns, `r${i}`))), next]);
  assert.deepEqual(started(mixed), [], 'five publish runs and four releases run: no release starts');
  assert.deepEqual(started(decide([...publishing.slice(0, MAX - 1), next])), [next.metadata.name], 'PLANTED INNOCENT: eight publish runs leave a slot to a release of a ninth unit');
  const waitingPublishes = units.map((ns, i) => publish(ns, `q${i}`, {pending: true}));
  assert.equal(started(decide([...waitingPublishes, publish(NAMESPACES[MAX], 'q9', {pending: true})])).length, MAX, 'nine waiting publish runs start and the tenth waits');
  assert.equal(started(decide(waitingPublishes.slice(0, MAX - 1).concat(run(units[MAX - 1], 'r', {pending: true})))).length, MAX, 'PLANTED INNOCENT: publish and release runs of nine units start together');
});

test('release and publish runs of one unit exclude each other in both directions, for the same tag and for another', () => {
  for (const tag of ['a', 'b']) {
    const release = run('shop-build', 'a'), own = publish('shop-build', tag, {pending: true});
    assert.deepEqual(started(decide([release, own])), [], `a publish run of tag ${tag} waits for the release that runs`);
    const publishing = publish('shop-build', 'a'), next = run('shop-build', tag, {pending: true});
    assert.deepEqual(started(decide([publishing, next])), [], `a release of tag ${tag} waits for the publish run that runs`);
    assert.deepEqual(waiting(decide([publishing, next])), [[next.metadata.name, 'shop-build/a publish']]);
  }
  const first = publish('shop-build', 'a', {pending: true}), second = run('shop-build', 'b', {pending: true});
  assert.deepEqual(started(decide([second, first])), [first.metadata.name], 'of a waiting publish run and a waiting release of one unit the older starts');
});

test('a run notes a publish run it waits for apart from the release of the same tag', () => {
  const running = publish('post-build', 'b'), next = run('post-build', 'b', {pending: true});
  assert.deepEqual(waiting(decide([running, next])), [[next.metadata.name, 'post-build/b publish']]);
  assert.deepEqual(waiting(planted(' + (if isPublish then " publish" else "" end)', '', [running, next])), [[next.metadata.name, 'post-build/b']],
    'PLANTED DEFECT: a queue that keys a publish run like its release names the release as what the run waits for');
});

test('a namespace keeps its newest 20 finished publish runs beside its 20 releases, and a waiting or running publish run is never deleted', () => {
  const old = finished('shop-build', 21, 'shop-publish');
  const changes = decide([...old, ...finished('shop-build', 20), publish('shop-build', 'now'), publish('shop-build', 'next', {pending: true})]);
  assert.deepEqual(deleted(changes), [old[0].metadata.name], 'only the oldest of 21 finished publish runs goes');
  assert.deepEqual(deleted(decide([...finished('shop-build', 20, 'shop-publish'), publish('shop-build', 'now')])), [],
    'PLANTED INNOCENT: 20 finished publish runs and a running one: nothing is deleted');
});

test('planted defect: a queue that counts publish and release runs together deletes releases the real one keeps', () => {
  const items = [...finished('shop-build', 20), ...finished('shop-build', 1, 'shop-publish')];
  assert.equal(deleted(planted('group_by([.metadata.namespace, .spec.pipelineRef.name])', 'group_by(.metadata.namespace)', items)).length, 1);
  assert.deepEqual(deleted(decide(items)), []);
});

test('starts come before notes, so a note that cannot be written never holds a start back', () => {
  const a = run('shop-build', 'a'), c = run('auth-build', 'c'), b = run('post-build', 'b', {pending: true}), a2 = run('shop-build', 'a', {pending: true});
  assert.deepEqual(decide([a, c, b, a2]).map((x) => x.type), ['json', 'merge']);
});

// The tick runs the kubectl on the PATH against a stand-in API server, so the requests it makes and the
// memory it takes are kubectl's own. The server answers discovery, lists runs by label key and by page as
// the API server does, with a continue token that holds a "+", and takes patches and deletes, refusing
// those to a run named in refuse, as a unit whose grant has not synced yet would. The memory is the summed
// resident size of the tick's processes, sampled while it runs; it counts a shared page once per process,
// so it is more than the container's cgroup is charged. A tick past limitKiB is killed.
const TICK = 'clusters/inventories/image-builder/files/release-queue.sh';
const DISCOVERY = {
  '/api': {kind: 'APIVersions', versions: ['v1']},
  '/api/v1': {kind: 'APIResourceList', groupVersion: 'v1', resources: []},
  '/apis': {kind: 'APIGroupList', apiVersion: 'v1', groups: [{name: 'tekton.dev',
    versions: [{groupVersion: 'tekton.dev/v1', version: 'v1'}], preferredVersion: {groupVersion: 'tekton.dev/v1', version: 'v1'}}]},
  '/apis/tekton.dev/v1': {kind: 'APIResourceList', apiVersion: 'v1', groupVersion: 'tekton.dev/v1',
    resources: [{name: 'pipelineruns', singularName: 'pipelinerun', namespaced: true, kind: 'PipelineRun', verbs: ['get', 'list', 'patch', 'delete']}]},
};
const answer = (items, refuse, url, method) => {
  if (method === 'GET' && DISCOVERY[url.pathname]) return [200, DISCOVERY[url.pathname]];
  if (method === 'GET' && url.pathname === '/apis/tekton.dev/v1/pipelineruns') {
    const selector = url.searchParams.get('labelSelector'), token = url.searchParams.get('continue');
    if (token !== null && !/^page\+\d+=$/.test(token)) return [400, {kind: 'Status', code: 400, message: `bad continue token ${token}`}];
    const listed = items.filter((r) => selector === null || Object.hasOwn(r.metadata.labels, selector));
    const from = token === null ? 0 : Number(token.slice(5, -1)), to = from + (Number(url.searchParams.get('limit')) || listed.length);
    return [200, {apiVersion: 'tekton.dev/v1', kind: 'PipelineRunList', metadata: to < listed.length ? {continue: `page+${to}=`} : {},
      items: listed.slice(from, to).map((r) => ({apiVersion: 'tekton.dev/v1', kind: 'PipelineRun', ...r}))}];
  }
  const [, namespace, name] = /^\/apis\/tekton\.dev\/v1\/namespaces\/([^/]+)\/pipelineruns\/([^/]+)$/.exec(url.pathname) ?? [];
  const target = items.find((r) => r.metadata.namespace === namespace && r.metadata.name === name);
  if (!target || !['GET', 'PATCH', 'DELETE'].includes(method)) return [404, {kind: 'Status', apiVersion: 'v1', status: 'Failure', reason: 'NotFound', code: 404}];
  if (method !== 'GET' && refuse.includes(name)) return [403, {kind: 'Status', apiVersion: 'v1', status: 'Failure', reason: 'Forbidden', code: 403, message: 'forbidden'}];
  return [200, {apiVersion: 'tekton.dev/v1', kind: 'PipelineRun', ...target}];
};
const residentKiB = (pid) => {
  try {
    return Number(/VmRSS:\s+(\d+)/.exec(readFileSync(`/proc/${pid}/status`, 'utf8'))?.[1] ?? 0);
  } catch {
    // The process ended between two reads.
    return 0;
  }
};
const processTree = (pid) => {
  let children = [];
  try {
    children = readdirSync(`/proc/${pid}/task`).flatMap((task) => readFileSync(`/proc/${pid}/task/${task}/children`, 'utf8').split(' ').filter(Boolean).map(Number));
  } catch {
    // The process ended between two reads.
  }
  return [pid, ...children.flatMap(processTree)];
};
async function tick(items, {script = TICK, refuse = [], failLabel, limitKiB = Infinity} = {}) {
  const requests = [];
  const server = createServer((request, response) => {
    let body = '';
    request.on('data', (chunk) => { body += chunk; });
    request.on('end', () => {
      const url = new URL(request.url, 'http://api.invalid');
      if (!DISCOVERY[url.pathname]) requests.push({method: request.method, url, type: request.headers['content-type'], body});
      const [code, reply] = url.searchParams.get('labelSelector') === failLabel ? [500, {kind: 'Status', code: 500, message: 'the server timed out'}]
        : answer(items, refuse, url, request.method);
      response.writeHead(code, {'content-type': 'application/json'});
      response.end(JSON.stringify(reply));
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const home = mkdtempSync(join(tmpdir(), 'release-queue-'));
  try {
    writeFileSync(join(home, 'kubeconfig'), JSON.stringify({apiVersion: 'v1', kind: 'Config', 'current-context': 'standin',
      clusters: [{name: 'standin', cluster: {server: `http://127.0.0.1:${server.address().port}`}}],
      contexts: [{name: 'standin', context: {cluster: 'standin', user: 'standin'}}], users: [{name: 'standin', user: {}}]}));
    const child = spawn('bash', [script], {detached: true,
      env: {...process.env, KUBECONFIG: join(home, 'kubeconfig'), HOME: home, QUEUE_DIR: 'clusters/inventories/image-builder/files', RELEASE_MAX_RUNNING: String(MAX)}});
    let stdout = '', stderr = '', peakKiB = 0, killed = false;
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    const sampler = setInterval(() => {
      peakKiB = Math.max(peakKiB, processTree(child.pid).reduce((sum, pid) => sum + residentKiB(pid), 0));
      if (peakKiB > limitKiB && !killed) {
        killed = true;
        process.kill(-child.pid, 'SIGKILL');
      }
    }, 2);
    const status = await new Promise((resolve) => child.on('close', resolve));
    clearInterval(sampler);
    const lines = (text) => text.split('\n').filter(Boolean);
    return {status, stdout: lines(stdout), stderr, peakKiB, requests,
      lists: requests.filter((r) => r.method === 'GET' && r.url.pathname.endsWith('/pipelineruns'))
        .map((r) => ({path: r.url.pathname, ...Object.fromEntries(r.url.searchParams)})),
      writes: requests.filter((r) => r.method !== 'GET')};
  } finally {
    server.close();
    rmSync(home, {recursive: true, force: true});
  }
}
const planTick = (from, to) => {
  const text = readFileSync(TICK, 'utf8');
  assert.ok(text.includes(from), `the tick carries ${from}`);
  const dir = mkdtempSync(join(tmpdir(), 'release-queue-'));
  writeFileSync(join(dir, 'release-queue.sh'), text.replace(from, to));
  return {script: join(dir, 'release-queue.sh'), done: () => rmSync(dir, {recursive: true, force: true})};
};
// The listing as the tick had it before it paged: every PipelineRun of the cluster, decoded by kubectl at once.
const unboundedTick = () => planTick(
  `{ list_pipelineruns image-builder.io/consumer "$queue_run" && list_pipelineruns image-builder.io/publish "$queue_run"; } \\\n  | jq -cs '{items: .}' | jq -c --argjson max "\$max" -f "\${QUEUE_DIR}/release-queue.jq"`,
  'kubectl get pipelineruns -A -o json | jq -c --argjson max "$max" -f "${QUEUE_DIR}/release-queue.jq"');

// A run as the API server returns it: the resolved pipeline in status.pipelineSpec (about 31 KB of a 35 KB
// run on the master), the pipeline label Tekton sets and conditions the decision never reads.
const pipelineSpec = {tasks: Array.from({length: 40}, (_, i) => ({name: `task-${i}`, taskSpec: {steps: [{name: 'run', image: 'alpine/k8s:1.35.6', script: 'x'.repeat(700)}]}}))};
const asServed = (r) => ({...r,
  metadata: {...r.metadata, uid: `uid-${r.metadata.name}`, labels: {...r.metadata.labels, 'tekton.dev/pipeline': r.spec.pipelineRef.name}},
  spec: {...r.spec, params: [...r.spec.params, {name: 'revision', value: 'a'.repeat(40)}]},
  status: {...r.status, pipelineSpec, conditions: [...(r.status.conditions ?? []).map((c) => ({...c, reason: 'Done'})), {type: 'Ready', status: 'True'}]}});
// 17 build namespaces, each keeping 20 finished release, publish and image runs, with one release run past
// the twenty, one release that runs, its publish run waiting behind it and another release of another unit
// that starts, and a waiting run elsewhere whose pipeline ends in -release: 1025 runs, 684 of them the queue's.
const steadyState = () => {
  const units = Array.from({length: 17}, (_, i) => `unit${i}-build`);
  return [
    ...units.flatMap((ns) => [...finished(ns, 20), ...finished(ns, 20, ns.replace(/-build$/, '-publish')), ...finished(ns, 20, ns.replace(/-build$/, '-image'))]),
    ...finished(units[0], 1), run(units[1], 'a'), publish(units[1], 'a', {pending: true}), run(units[2], 'b', {pending: true}),
    run('tools', 'x', {pending: true, pipeline: 'tools-release', labels: {}}),
  ].map(asServed);
};
const queuesRun = (r) => Object.hasOwn(r.metadata.labels, 'image-builder.io/consumer') || Object.hasOwn(r.metadata.labels, 'image-builder.io/publish');
const cronLimitKiB = () => {
  const cron = renderChart('image-builder').find((d) => d.kind === 'CronJob' && d.metadata.name === 'release-queue');
  const [, amount, unit] = /^(\d+)(Ki|Mi|Gi)$/.exec(cron.spec.jobTemplate.spec.template.spec.containers[0].resources.limits.memory);
  return Number(amount) * {Ki: 1, Mi: 1024, Gi: 1024 * 1024}[unit];
};

test('the tick lists the queue\'s runs by their two labels, 50 a page, within its memory limit, and decides as the full runs decide', async () => {
  const items = steadyState(), limitKiB = cronLimitKiB();
  assert.equal(limitKiB, 128 * 1024);
  assert.deepEqual([items.length, items.filter(queuesRun).length], [1025, 684]);
  const expected = decide(items.filter(queuesRun));
  assert.deepEqual([...new Set(expected.map((c) => c.verb ?? c.type))].sort(), ['delete', 'json', 'merge']);
  const result = await tick(items, {limitKiB});
  assert.equal(result.status, 0, result.stderr);
  assert.ok(result.peakKiB > 0 && result.peakKiB <= limitKiB, `the tick took ${result.peakKiB} KiB of ${limitKiB}`);
  // The cut runs drop nothing the decision reads: the same changes come out, in the same order, and the
  // run elsewhere is neither started nor noted.
  assert.deepEqual(result.stdout, expected.map((c) => c.say));
  assert.equal(result.writes.length, expected.length);
  assert.ok(result.writes.every((w) => w.url.pathname.includes('/namespaces/unit')), 'the run elsewhere is not touched');
  const pages = (label) => Math.ceil(items.filter((r) => Object.hasOwn(r.metadata.labels, label)).length / 50);
  assert.deepEqual(result.lists, ['image-builder.io/consumer', 'image-builder.io/publish'].flatMap((label) =>
    Array.from({length: pages(label)}, (_, page) => ({path: '/apis/tekton.dev/v1/pipelineruns', labelSelector: label, limit: '50',
      ...(page ? {continue: `page+${page * 50}=`} : {})}))));
});

test('planted defect: a tick that lists every run unbounded goes past the memory limit and lists runs that are not the queue\'s', async () => {
  const items = steadyState(), limitKiB = cronLimitKiB(), planted = unboundedTick();
  try {
    const result = await tick(items, {script: planted.script, limitKiB});
    assert.ok(result.peakKiB > limitKiB, `the unbounded tick took ${result.peakKiB} KiB, within ${limitKiB}`);
    assert.notEqual(result.status, 0, 'the unbounded tick is killed at the limit');
    assert.ok(result.lists.some((list) => !['image-builder.io/consumer', 'image-builder.io/publish'].includes(list.labelSelector) || list.limit !== '50'),
      'the unbounded tick lists without a label selector and a page of 50');
  } finally {
    planted.done();
  }
});

test('planted defect: a tick that lists every run starts a waiting run elsewhere whose pipeline ends in -release', async () => {
  const items = [run('tools', 'x', {pending: true, pipeline: 'tools-release', labels: {}}), run('shop-build', 'a', {pending: true})];
  const planted = unboundedTick();
  try {
    const wrong = await tick(items, {script: planted.script});
    assert.equal(wrong.status, 0, wrong.stderr);
    assert.match(wrong.stdout[0], /^started tools\/x-\d+ /, 'the unbounded tick starts the run elsewhere');
    const right = await tick(items);
    assert.deepEqual(right.stdout.map((line) => line.replace(/-\d+ /, ' ')), ['started shop-build/a (release shop-build/a)'],
      'PLANTED INNOCENT: the real tick starts the release and leaves the run elsewhere alone');
  } finally {
    planted.done();
  }
});

test('planted defect: a tick that lists only the release label never starts a publish run', async () => {
  const items = [publish('shop-build', 'a', {pending: true})];
  const planted = planTick(' && list_pipelineruns image-builder.io/publish "$queue_run"', '');
  try {
    const wrong = await tick(items, {script: planted.script});
    assert.deepEqual([wrong.status, wrong.stdout], [0, []]);
    const right = await tick(items);
    assert.equal(right.status, 0, right.stderr);
    assert.deepEqual(right.writes.map((w) => [w.method, w.url.pathname, w.type, JSON.parse(w.body)]),
      [['PATCH', `/apis/tekton.dev/v1/namespaces/shop-build/pipelineruns/${items[0].metadata.name}`, 'application/json-patch+json', [{op: 'remove', path: '/spec/status'}]]]);
  } finally {
    planted.done();
  }
});

test('planted defect: a patch that fails is reported, the next ones still run, and the tick fails', async () => {
  const runs = NAMESPACES.map((ns, i) => run(ns, `t${i}`, {pending: true}));
  const result = await tick(runs, {refuse: [runs[0].metadata.name]});
  assert.equal(result.status, 1);
  assert.match(result.stderr, /could not patch unit0-build\//);
  assert.deepEqual(result.writes.map((w) => w.url.pathname.split('/').at(-1)), runs.map((r) => r.metadata.name));
  assert.match(result.stdout.join('\n'), /started unit1-build\//);
  assert.ok(result.stdout.join('\n').includes(`${NAMESPACES[MAX]}/${runs[MAX].metadata.name} (release ${NAMESPACES[MAX]}/t${MAX}) waits for release ${releasesOf(runs.slice(0, MAX))}`));
});

test('a list that fails fails the tick, and nothing is changed on part of the runs', async () => {
  const items = [run('shop-build', 'a'), run('auth-build', 'c'), publish('post-build', 'b', {pending: true})];
  const result = await tick(items, {failLabel: 'image-builder.io/consumer'});
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /InternalError/);
  assert.deepEqual(result.writes, [], 'the publish run is not started beside the releases the tick did not see');
  const planted = planTick('"$queue_run" && list_pipelineruns image-builder.io/publish', '"$queue_run" || true; list_pipelineruns image-builder.io/publish');
  try {
    const wrong = await tick(items, {script: planted.script, failLabel: 'image-builder.io/consumer'});
    assert.match(wrong.stdout.join('\n'), /^started post-build\//, 'the planted tick starts the publish run on part of the runs');
  } finally {
    planted.done();
  }
});

test('the tick deletes the run the decision names, in its namespace, without waiting for its pods', async () => {
  const old = finished('shop-build', 21);
  const result = await tick(old);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.writes.map((w) => [w.method, w.url.pathname]), [['DELETE', `/apis/tekton.dev/v1/namespaces/shop-build/pipelineruns/${old[0].metadata.name}`]]);
  assert.match(result.stdout.join('\n'), new RegExp(`deleted shop-build/${old[0].metadata.name}`));
});

// The admission policy's clause for the queue, evaluated on planted requests by scripts/vap-eval,
// which runs the CEL library the build plane's API server runs.
const guard = () => renderChart('image-builder').find((d) => d.kind === 'ValidatingAdmissionPolicy' && d.metadata.name === 'image-builder-pipelinerun-guard');
const evaluate = (policy, requests) => execFileSync('go', ['run', '.'], {cwd: 'scripts/vap-eval', encoding: 'utf8',
  input: JSON.stringify({policy, requests})}).split('\n').filter(Boolean).map((line) => JSON.parse(line).denied);

const QUEUE_SA = 'system:serviceaccount:image-builder:release-queue';
const waitingRun = () => ({
  metadata: {name: 'shop-release-x', namespace: 'shop-build', labels: {'image-builder.io/consumer': 'shop'},
    annotations: {'chains.tekton.dev/signed': 'false'}, finalizers: ['chains.tekton.dev/pipelinerun']},
  spec: {status: 'PipelineRunPending', pipelineRef: {name: 'shop-release'},
    params: [{name: 'release-tag', value: '1.0.0-stable-1'}, {name: 'stage', value: 'prod'}],
    taskRunTemplate: {serviceAccountName: 'pipeline-sa', podTemplate: {priorityClassName: 'image-builder-release'}}, timeouts: {pipeline: '1h0m0s'},
    workspaces: [{name: 'source', volumeClaimTemplate: {spec: {accessModes: ['ReadWriteOnce']}}}]},
});
const changed = (edit) => { const run = waitingRun(); edit(run); return run; };
const asks = (operation, username, object, oldObject) => ({object, oldObject, request: {operation, namespace: 'shop-build', userInfo: {username}}});
const startedRun = changed((r) => delete r.spec.status);
const asPublish = (r) => { r.spec.pipelineRef.name = 'shop-publish'; r.metadata.labels = {'image-builder.io/publish': 'shop'}; };
const ADMITTED = {
  'the EventListener creates a waiting run': asks('CREATE', 'system:serviceaccount:image-builder:eventlistener-sa', waitingRun(), null),
  'the queue starts a waiting run': asks('UPDATE', QUEUE_SA, startedRun, waitingRun()),
  'the queue notes what a run waits for, beside other annotations': asks('UPDATE', QUEUE_SA, changed((r) => { r.metadata.annotations['image-builder.io/queued-behind'] = 'post-build/b'; }), waitingRun()),
  'the queue starts a run and drops its note': asks('UPDATE', QUEUE_SA, startedRun, changed((r) => { r.metadata.annotations['image-builder.io/queued-behind'] = 'post-build/b'; })),
  'the queue starts a waiting publish run': asks('UPDATE', QUEUE_SA, changed((r) => { asPublish(r); delete r.spec.status; }), changed(asPublish)),
  'the Tekton controller updates a started run': asks('UPDATE', 'system:serviceaccount:tekton:tekton-controller', changed((r) => { delete r.spec.status; r.metadata.labels['tekton.dev/pipeline'] = 'shop-release'; }), startedRun),
};
const DENIED = {
  'the queue changes a param': asks('UPDATE', QUEUE_SA, changed((r) => { delete r.spec.status; r.spec.params[0].value = 'other'; }), waitingRun()),
  'the queue drops the timeouts while starting': asks('UPDATE', QUEUE_SA, changed((r) => { delete r.spec.status; delete r.spec.timeouts; }), waitingRun()),
  'the queue cancels a waiting run': asks('UPDATE', QUEUE_SA, changed((r) => { r.spec.status = 'Cancelled'; }), waitingRun()),
  'the queue puts a started run back to waiting': asks('UPDATE', QUEUE_SA, waitingRun(), startedRun),
  'the queue creates a run': asks('CREATE', QUEUE_SA, waitingRun(), null),
  'the queue changes a label': asks('UPDATE', QUEUE_SA, changed((r) => { r.metadata.labels['image-builder.io/consumer'] = 'post'; }), waitingRun()),
  'the queue adds another annotation': asks('UPDATE', QUEUE_SA, changed((r) => { r.metadata.annotations['chains.tekton.dev/x'] = 'y'; }), waitingRun()),
  'the queue changes another annotation': asks('UPDATE', QUEUE_SA, changed((r) => { r.metadata.annotations['chains.tekton.dev/signed'] = 'true'; }), waitingRun()),
  'the queue removes another annotation': asks('UPDATE', QUEUE_SA, changed((r) => { delete r.metadata.annotations; }), waitingRun()),
  'the queue changes the finalizers': asks('UPDATE', QUEUE_SA, changed((r) => { r.metadata.finalizers = []; }), waitingRun()),
};
const QUEUE_MESSAGE = 'the release queue may only start a waiting release or publish run or note what it waits for.';

test('the admission policy lets the queue start a waiting run or note what it waits for, and nothing else', () => {
  const policy = guard();
  const verdicts = evaluate(policy, [...Object.values(ADMITTED), ...Object.values(DENIED)]);
  Object.keys(ADMITTED).forEach((name, i) => assert.deepEqual(verdicts[i], [], name));
  Object.keys(DENIED).forEach((name, i) => assert.deepEqual(verdicts[Object.keys(ADMITTED).length + i], [QUEUE_MESSAGE], name));
});

test('planted defect: without the queue clause, every change the queue must not make is admitted', () => {
  const policy = guard();
  policy.spec.validations = policy.spec.validations.filter((v) => v.message !== QUEUE_MESSAGE);
  assert.ok(evaluate(policy, Object.values(DENIED)).every((denied) => denied.length === 0));
});

// A delete is admitted from oldObject alone: object is null. A run is finished when its Succeeded condition
// is True or False, as the queue's jq reads it.
const DASHBOARD = 'system:serviceaccount:tekton-pipelines:tekton-dashboard';
const withStatus = (status, edit = () => {}) => changed((r) => { delete r.spec.status; r.status = status; edit(r); });
const succeeded = (status, edit) => withStatus({conditions: [{type: 'Succeeded', status}]}, edit);
const deletes = (username, oldObject) => asks('DELETE', username, null, oldObject);
const QUEUE_DELETE_MESSAGE = 'the release queue may only delete a finished release or publish run of its own namespace.';
const DELETE_ADMITTED = {
  'the queue deletes a release run that succeeded': deletes(QUEUE_SA, succeeded('True')),
  'the queue deletes a release run that failed': deletes(QUEUE_SA, succeeded('False')),
  'the queue deletes a publish run that succeeded': deletes(QUEUE_SA, succeeded('True', asPublish)),
  'the Tekton Dashboard deletes a running release run': deletes(DASHBOARD, succeeded('Unknown')),
  'a user deletes a waiting release run': deletes('owner@example.com', waitingRun()),
  'a user deletes a run that breaks every other clause': deletes('owner@example.com', {metadata: {name: 'x', namespace: 'shop-build'}, spec: {}}),
};
const DELETE_DENIED = {
  'the queue deletes a running release run': deletes(QUEUE_SA, succeeded('Unknown')),
  'the queue deletes a running publish run': deletes(QUEUE_SA, succeeded('Unknown', asPublish)),
  'the queue deletes a finished run of another unit\'s publish pipeline': deletes(QUEUE_SA, succeeded('True', (r) => { asPublish(r); r.spec.pipelineRef.name = 'post-publish'; })),
  'the queue deletes a pending release run': deletes(QUEUE_SA, waitingRun()),
  'the queue deletes a release run with an empty status': deletes(QUEUE_SA, withStatus({})),
  'the queue deletes a release run with another condition only': deletes(QUEUE_SA, withStatus({conditions: [{type: 'Ready', status: 'True'}]})),
  'the queue deletes a finished run of another unit\'s release pipeline': deletes(QUEUE_SA, succeeded('True', (r) => { r.spec.pipelineRef.name = 'post-release'; })),
  'the queue deletes a finished run without a pipeline': deletes(QUEUE_SA, succeeded('True', (r) => { delete r.spec.pipelineRef; })),
};

test('the admission policy sees a delete, and lets the queue delete a finished release or publish run of its own namespace and no other run', () => {
  const policy = guard();
  assert.ok(policy.spec.matchConstraints.resourceRules.every((rule) => rule.operations.includes('DELETE')));
  const verdicts = evaluate(policy, [...Object.values(DELETE_ADMITTED), ...Object.values(DELETE_DENIED)]);
  Object.keys(DELETE_ADMITTED).forEach((name, i) => assert.deepEqual(verdicts[i], [], `PLANTED INNOCENT: ${name}`));
  Object.keys(DELETE_DENIED).forEach((name, i) => assert.deepEqual(verdicts[Object.keys(DELETE_ADMITTED).length + i], [QUEUE_DELETE_MESSAGE], `PLANTED DEFECT: ${name}`));
});

test('planted defect: without the queue delete clause, every run the queue must not delete is admitted', () => {
  const policy = guard();
  policy.spec.validations = policy.spec.validations.filter((v) => v.message !== QUEUE_DELETE_MESSAGE);
  assert.ok(evaluate(policy, Object.values(DELETE_DENIED)).every((denied) => denied.length === 0));
});

test('planted defect: a clause that reads object without stepping aside refuses every delete, the Tekton Dashboard\'s too', () => {
  const policy = guard();
  policy.spec.validations = policy.spec.validations.map((v) => ({...v, expression: v.expression.replace("request.operation == 'DELETE' || ", '')}));
  assert.ok(evaluate(policy, [DELETE_ADMITTED['the Tekton Dashboard deletes a running release run']])[0].length > 0);
});
