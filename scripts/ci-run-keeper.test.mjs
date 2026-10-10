import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

// The ci run keeper starts the oldest waiting ci runs while fewer than MAX ci runs run, cancels a ci run
// that a newer push to the same branch replaces, and keeps the newest 20 finished ci runs of each build
// namespace. Its decision is the jq program in
// clusters/inventories/image-builder/files, run here on planted PipelineRuns; its script is run
// against a stand-in kubectl. The CronJob, its rights and the admission policy clause for it are
// asserted in scripts/build-contract.test.mjs.

const FILES = 'clusters/inventories/image-builder/files';
const KEPT = 20;
const MAX = 6;
const REASON = `all ${MAX} ci slots are in use`;
const UNIT_REASON = 'a ci run of this unit runs';
const namespaces = (count) => Array.from({length: count}, (_, i) => `unit${i + 1}-build`);

let clock = 0;
const timestamp = (minute) => new Date(Date.UTC(2026, 9, 9) + minute * 60000).toISOString().replace('.000Z', 'Z');
// Every run is created a minute after the one before, on a branch of its own unless it is given one.
// succeeded: 'True' and 'False' are finished, 'Unknown' is a run that waits for the quota or runs.
const run = (namespace, {ci = true, succeeded, branch = `branch-${clock + 1}`, status, at} = {}) => {
  const unit = namespace.replace(/-build$/, '');
  const minute = at ?? ++clock;
  return {
    metadata: {namespace, name: `${unit}-${ci ? 'ci' : 'release'}-${minute}-${Math.random().toString(16).slice(2, 7)}`,
      creationTimestamp: timestamp(minute),
      labels: ci ? {'image-builder.io/ci': unit} : {'image-builder.io/consumer': unit},
      annotations: branch === null ? {} : {'image-builder.io/ci-branch': branch}},
    spec: {pipelineRef: {name: `${unit}-${ci ? 'ci' : 'release'}`}, ...(status ? {status} : {})},
    status: succeeded === undefined ? {} : {conditions: [{type: 'Succeeded', status: succeeded}]},
  };
};
const finished = (count, namespace, options = {}) => Array.from({length: count}, () => run(namespace, {succeeded: 'True', ...options}));
// A run that waits for a slot: created as the ci-push TriggerTemplate creates it.
const waiting = (namespace, options = {}) => run(namespace, {status: 'PipelineRunPending', succeeded: 'Unknown', ...options});
const running = (count, namespace) => Array.from({length: count}, () => run(namespace, {succeeded: 'Unknown'}));
const decideWith = (program, items, max = MAX) => {
  const dir = mkdtempSync(join(tmpdir(), 'ci-run-keeper-jq-'));
  try {
    const file = join(dir, 'decision.jq');
    writeFileSync(file, program);
    return execFileSync('jq', ['-c', '--argjson', 'max', String(max), '-f', file], {input: JSON.stringify({items}), encoding: 'utf8'})
      .split('\n').filter(Boolean).map((line) => JSON.parse(line));
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
};
const PROGRAM = readFileSync(`${FILES}/ci-run-keeper.jq`, 'utf8');
const decide = (items, max = MAX) => decideWith(PROGRAM, items, max);
const started = (items, max) => decide(items, max).filter((c) => c.verb === 'patch' && c.type === 'json').map((c) => c.name).sort();
const noted = (items, max) => decide(items, max).filter((c) => c.verb === 'patch' && c.type === 'merge').map((c) => c.name).sort();
const only = (verb) => (items) => decide(items).filter((c) => c.verb === verb).map((c) => c.name).sort();
const cancelled = only('cancel'), deleted = only('delete');
const names = (runs) => runs.map((r) => r.metadata.name).sort();

test('a finished run beyond the newest 20 is deleted, the oldest first', () => {
  const runs = finished(KEPT + 5, 'shop-build');
  assert.deepEqual(deleted(runs), names(runs.slice(0, 5)));
  assert.deepEqual(cancelled(runs), []);
});

test('planted innocent: 20 finished runs and 1 running run stay, whichever of them is the newest', () => {
  assert.deepEqual(decide([run('shop-build'), ...finished(KEPT, 'shop-build')]), []);
  assert.deepEqual(decide([...finished(KEPT, 'shop-build'), run('shop-build')]), []);
});

test('planted defect: a running run beyond the newest 20 is not deleted, but the finished run beyond them is', () => {
  const runs = [run('shop-build'), ...finished(KEPT + 1, 'shop-build')];
  assert.deepEqual(deleted(runs), [runs[1].metadata.name]);
});

test('planted defect: a release run is neither cancelled nor deleted, however many there are and whatever it carries', () => {
  // The bait: release runs that carry the branch annotation, two of them on one branch.
  const releases = [...finished(KEPT + 10, 'shop-build', {ci: false}), run('shop-build', {ci: false, branch: 'main'}), run('shop-build', {ci: false, branch: 'main'})];
  assert.deepEqual(decide(releases), []);
  const ci = finished(KEPT + 1, 'shop-build');
  assert.deepEqual(deleted([...releases, ...ci]), [ci[0].metadata.name]);
});

test('each build namespace keeps its own 20, and a failed run is a finished run', () => {
  const shop = finished(KEPT, 'shop-build'), post = finished(KEPT, 'post-build');
  assert.deepEqual(decide([...shop, ...post]), []);
  const failed = run('post-build', {succeeded: 'False'});
  assert.deepEqual(deleted([...shop, failed, ...finished(KEPT, 'post-build')]), [failed.metadata.name]);
});

test('a newer push replaces the older run of its branch, whether that waits for the quota or runs', () => {
  const waiting = run('shop-build', {branch: 'main', succeeded: 'Unknown'}), running = run('shop-build', {branch: 'main'});
  const newest = run('shop-build', {branch: 'main'});
  assert.deepEqual(cancelled([newest, running, waiting]), names([waiting, running]));
});

// A started run has set its commit status to pending, so it is cancelled with its finally tasks, which set
// the status it ends with; a waiting run has set none and runs no task at all.
test('a replaced run that has started is cancelled gracefully, and a replaced run that waits outright', () => {
  const statuses = (program, items) => Object.fromEntries(decideWith(program, items).filter((c) => c.verb === 'cancel')
    .map((c) => [c.name, c.patch.spec.status]));
  const queued = waiting('shop-build', {branch: 'main'}), started = run('shop-build', {branch: 'main', succeeded: 'Unknown'});
  const newest = run('shop-build', {branch: 'main'});
  const expected = {[queued.metadata.name]: 'Cancelled', [started.metadata.name]: 'CancelledRunFinally'};
  assert.deepEqual(statuses(PROGRAM, [queued, started, newest]), expected);
  const graceless = 'patch: {spec: {status: (if isPending then "Cancelled" else "CancelledRunFinally" end)}}';
  assert.ok(PROGRAM.includes(graceless));
  assert.notDeepEqual(statuses(PROGRAM.replace(graceless, 'patch: {spec: {status: "Cancelled"}}'), [queued, started, newest]), expected,
    'PLANTED DEFECT: a keeper that cancels a started run outright leaves its commit status at pending');
});

test('planted defect: the newest run of a branch is not cancelled', () => {
  const older = run('shop-build', {branch: 'main'}), newest = run('shop-build', {branch: 'main'});
  assert.deepEqual(cancelled([older, newest]), [older.metadata.name]);
  assert.deepEqual(cancelled([newest]), []);
});

test('planted innocent: two branches with one running run each stay untouched, and so does one branch name in two build namespaces', () => {
  assert.deepEqual(decide([run('shop-build', {branch: 'main'}), run('shop-build', {branch: 'feature/x'})]), []);
  assert.deepEqual(decide([run('shop-build', {branch: 'main'}), run('post-build', {branch: 'main'})]), []);
});

test('a run is not cancelled when it has finished, is cancelled already, has no branch, or ties with the newest', () => {
  const done = run('shop-build', {branch: 'main', succeeded: 'True'}), stopped = run('shop-build', {branch: 'main', status: 'Cancelled'});
  const stopping = run('shop-build', {branch: 'main', status: 'CancelledRunFinally', succeeded: 'Unknown'});
  const noBranchA = run('shop-build', {branch: null}), noBranchB = run('shop-build', {branch: null});
  const newest = run('shop-build', {branch: 'main'});
  assert.deepEqual(cancelled([done, stopped, stopping, noBranchA, noBranchB, newest]), []);
  // Two pushes in the same second cannot be ordered, so neither replaces the other.
  const first = run('post-build', {branch: 'main', at: 500}), second = run('post-build', {branch: 'main', at: 500});
  assert.deepEqual(cancelled([first, second]), []);
  assert.deepEqual(cancelled([first, second, run('post-build', {branch: 'main', at: 501})]), names([first, second]));
});

test('7 waiting runs of 7 units and none running start the 6 oldest, and the 7th waits with its reason', () => {
  const runs = namespaces(MAX + 1).map((namespace) => waiting(namespace));
  assert.deepEqual(started(runs), names(runs.slice(0, MAX)));
  const note = decide(runs).find((c) => c.type === 'merge');
  assert.equal(note.name, runs[MAX].metadata.name);
  assert.deepEqual(note.patch, {metadata: {annotations: {'image-builder.io/queued-behind': REASON}}});
  assert.deepEqual(decide(runs).map((c) => c.type), [...Array(MAX).fill('json'), 'merge'], 'starts come before notes');
});

test('6 running runs start none, and every waiting run waits with its reason', () => {
  const waits = [waiting('shop-build'), waiting('post-build')];
  assert.deepEqual(started([...running(MAX, 'shop-build'), ...waits]), []);
  assert.deepEqual(noted([...running(MAX, 'shop-build'), ...waits]), names(waits));
});

test('a free slot is a slot: 4 running runs and 3 waiting runs start the 2 oldest', () => {
  const waits = ['a-build', 'b-build', 'c-build'].map((namespace) => waiting(namespace));
  assert.deepEqual(started([...running(4, 'post-build'), ...waits]), names(waits.slice(0, 2)));
});

test('a finished run holds no slot, and a started run holds one whatever its pods wait for', () => {
  const waits = [waiting('shop-build')];
  assert.deepEqual(started([...finished(MAX, 'post-build'), ...waits]), names(waits));
  assert.deepEqual(started([...running(MAX - 1, 'post-build'), run('post-build', {status: 'CancelledRunFinally', succeeded: 'Unknown'}), ...waits]), []);
});

test('a waiting run that a newer push replaces is cancelled and never started, and takes no slot', () => {
  const old = waiting('shop-build', {branch: 'main'}), newest = waiting('shop-build', {branch: 'main'});
  const others = namespaces(MAX - 1).map((namespace) => waiting(namespace));
  const changes = decide([old, newest, ...others]);
  assert.deepEqual(changes.filter((c) => c.verb === 'cancel').map((c) => c.name), [old.metadata.name]);
  assert.deepEqual(started([old, newest, ...others]), names([newest, ...others]));
  assert.ok(!changes.some((c) => c.name === old.metadata.name && c.verb !== 'cancel'));
});

test('planted innocent: a release run is never touched, waiting or not, and holds no ci slot', () => {
  const releases = [...finished(KEPT + 3, 'shop-build', {ci: false}), run('shop-build', {ci: false, status: 'PipelineRunPending', succeeded: 'Unknown'}),
    ...Array.from({length: MAX + 1}, () => run('post-build', {ci: false, succeeded: 'Unknown'}))];
  assert.deepEqual(decide(releases), []);
  const ci = waiting('shop-build');
  assert.deepEqual(started([...releases, ci]), names([ci]));
});

test('the note is written once, and a start takes it back', () => {
  const noted = (r) => { r.metadata.annotations['image-builder.io/queued-behind'] = REASON; return r; };
  const waits = [noted(waiting('shop-build')), waiting('shop-build')];
  assert.deepEqual(decide([...running(MAX, 'post-build'), ...waits]).map((c) => c.name), [waits[1].metadata.name]);
  const start = decide([...running(MAX - 1, 'post-build'), ...waits]).find((c) => c.name === waits[0].metadata.name);
  assert.deepEqual(start.patch, [{op: 'remove', path: '/spec/status'}, {op: 'remove', path: '/metadata/annotations/image-builder.io~1queued-behind'}]);
  const plain = decide([...running(MAX - 1, 'post-build'), waits[1]]).find((c) => c.name === waits[1].metadata.name);
  assert.deepEqual(plain.patch, [{op: 'remove', path: '/spec/status'}]);
});

test('planted defect: a decision without the cap starts every waiting run, and the cap test goes red', () => {
  const cappedAtSix = (program) => {
    const runs = namespaces(MAX + 1).map((namespace) => waiting(namespace, {branch: null}));
    const starts = decideWith(program, runs).filter((c) => c.type === 'json');
    assert.equal(starts.length, MAX, `${starts.length} ci runs start at once`);
  };
  cappedAtSix(PROGRAM);
  assert.ok(PROGRAM.includes('[:$free]) as $startable'));
  assert.throws(() => cappedAtSix(PROGRAM.replace('[:$free]) as $startable', ') as $startable')), /7 ci runs start at once/);
});

const reasonOf = (changes, run) => changes.find((c) => c.name === run.metadata.name && c.type === 'merge')?.patch.metadata.annotations['image-builder.io/queued-behind'];

test('3 waiting runs of one unit and none running start only the oldest, and the others wait for it', () => {
  const waits = [waiting('shop-build'), waiting('shop-build'), waiting('shop-build')];
  assert.deepEqual(started(waits), names(waits.slice(0, 1)));
  assert.deepEqual(noted(waits), names(waits.slice(1)));
  assert.deepEqual(waits.slice(1).map((r) => reasonOf(decide(waits), r)), [UNIT_REASON, UNIT_REASON]);
});

test('a unit with a started run starts none, and another unit starts its oldest', () => {
  const [busy, free] = ['a-build', 'b-build'];
  const runs = [run(busy, {succeeded: 'Unknown'}), waiting(busy), waiting(free), waiting(free)];
  assert.deepEqual(started(runs), names([runs[2]]));
  const changes = decide(runs);
  assert.equal(reasonOf(changes, runs[1]), UNIT_REASON, 'the unit of a started run waits for it');
  assert.equal(reasonOf(changes, runs[3]), UNIT_REASON, 'the second run of a unit waits for the first');
});

test('6 waiting runs of 6 units all start, and a run of a 7th unit waits for a slot', () => {
  const six = namespaces(MAX).map((namespace) => waiting(namespace)), seventh = waiting('late-build');
  assert.deepEqual(started([...six, seventh]), names(six));
  assert.equal(reasonOf(decide([...six, seventh]), seventh), REASON);
  assert.equal(reasonOf(decide([...running(MAX, 'busy-build'), seventh]), seventh), REASON, 'a unit without a started run waits for a slot, not for itself');
});

test('planted defect: a keeper that starts two runs of one unit in one tick goes red', () => {
  const sameUnit = (program) => {
    const starts = decideWith(program, [waiting('shop-build'), waiting('shop-build')]).filter((c) => c.type === 'json');
    assert.equal(starts.length, 1, `${starts.length} ci runs of one unit start at once`);
  };
  sameUnit(PROGRAM);
  assert.ok(PROGRAM.includes('group_by(.metadata.namespace) | map(.[0])'));
  assert.throws(() => sameUnit(PROGRAM.replace('group_by(.metadata.namespace) | map(.[0])', 'sort_by(created, .metadata.name)')), /2 ci runs of one unit start at once/);
});

test('planted defect: a change that fails is reported, the next one still runs, and the tick fails', () => {
  const bin = mkdtempSync(join(tmpdir(), 'ci-run-keeper-'));
  try {
    const runs = join(bin, 'runs.json'), log = join(bin, 'log');
    // One cancellation first, then one deletion.
    const items = [run('shop-build', {branch: 'main'}), run('shop-build', {branch: 'main'}), ...finished(KEPT + 1, 'shop-build')];
    writeFileSync(runs, JSON.stringify({items}));
    // The first change is refused, as a unit whose grant has not synced yet would be.
    writeFileSync(join(bin, 'kubectl'), '#!/usr/bin/env bash\nif [ "$1" = get ]; then echo "$*" > "$LOG.get"; cat "$RUNS"; exit 0; fi\n'
      + 'echo "$*" >> "$LOG"\n[ "$(wc -l < "$LOG")" -gt 1 ]\n');
    chmodSync(join(bin, 'kubectl'), 0o755);
    const result = spawnSync('bash', [`${FILES}/ci-run-keeper.sh`], {encoding: 'utf8',
      env: {...process.env, PATH: bin + ':' + process.env.PATH, RUNS: runs, LOG: log, KEEPER_DIR: FILES, CI_MAX_RUNNING: String(MAX)}});
    assert.equal(result.status, 1);
    assert.match(result.stderr, /could not change shop-build\/shop-ci-/);
    const calls = readFileSync(log, 'utf8').trim().split('\n');
    assert.equal(calls.length, 2);
    assert.match(calls[0], /^patch pipelinerun -n shop-build shop-ci-\S+ --type merge -p \{"spec":\{"status":"CancelledRunFinally"\}\}$/);
    assert.match(calls[1], /^delete pipelinerun -n shop-build shop-ci-\S+ --ignore-not-found --wait=false$/);
    assert.match(result.stdout, /deleted shop-build\//);
    // Only ci runs are listed: the decision is never taken on a release run.
    assert.match(readFileSync(`${log}.get`, 'utf8'), / -l image-builder\.io\/ci /);
  } finally {
    rmSync(bin, {recursive: true, force: true});
  }
});

test('the script starts a waiting run with a json patch, and refuses to run without the cap', () => {
  const bin = mkdtempSync(join(tmpdir(), 'ci-run-keeper-'));
  try {
    const runs = join(bin, 'runs.json'), log = join(bin, 'log');
    const items = [...running(MAX - 2, 'post-build'), waiting('shop-build', {branch: null}), waiting('shop-build', {branch: null})];
    writeFileSync(runs, JSON.stringify({items}));
    writeFileSync(join(bin, 'kubectl'), '#!/usr/bin/env bash\nif [ "$1" = get ]; then cat "$RUNS"; exit 0; fi\necho "$*" >> "$LOG"\n');
    chmodSync(join(bin, 'kubectl'), 0o755);
    const env = {...process.env, PATH: bin + ':' + process.env.PATH, RUNS: runs, LOG: log, KEEPER_DIR: FILES};
    const result = spawnSync('bash', [`${FILES}/ci-run-keeper.sh`], {encoding: 'utf8', env: {...env, CI_MAX_RUNNING: String(MAX)}});
    assert.equal(result.status, 0, result.stderr);
    const calls = readFileSync(log, 'utf8').trim().split('\n');
    assert.equal(calls.length, 2);
    assert.match(calls[0], /^patch pipelinerun -n shop-build shop-ci-\S+ --type json -p \[\{"op":"remove","path":"\/spec\/status"\}\]$/);
    assert.match(calls[1], new RegExp(`^patch pipelinerun -n shop-build shop-ci-\\S+ --type merge -p \\{"metadata":\\{"annotations":\\{"image-builder.io/queued-behind":"${UNIT_REASON}"\\}\\}\\}$`));
    assert.match(result.stdout, /started shop-build\/shop-ci-/);
    const without = spawnSync('bash', [`${FILES}/ci-run-keeper.sh`], {encoding: 'utf8', env});
    assert.notEqual(without.status, 0);
    assert.match(without.stderr, /CI_MAX_RUNNING is required/);
  } finally {
    rmSync(bin, {recursive: true, force: true});
  }
});
