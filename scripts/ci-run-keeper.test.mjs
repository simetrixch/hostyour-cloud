import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

// The ci run keeper starts the oldest waiting ci runs while fewer than MAX ci runs run, cancels a ci run
// that a newer push to the same branch replaces and names that push on it, cancels a ci run whose `ci/` branch
// no longer exists on its remote and names that on it, and keeps the newest 20 finished ci runs of each build
// namespace. Its decision is the jq program in clusters/inventories/image-builder/files, run here on planted
// PipelineRuns and on planted answers of the remote; its script is run against a stand-in kubectl and a
// stand-in git. The CronJob, its rights and the admission policy clause for it are asserted in
// scripts/build-contract.test.mjs.

const FILES = 'clusters/inventories/image-builder/files';
const KEPT = 20;
const MAX = 7;
const REASON = `all ${MAX} ci slots are in use`;
const UNIT_REASON = 'a ci run of this unit runs';
const namespaces = (count) => Array.from({length: count}, (_, i) => `unit${i + 1}-build`);
const urlOf = (namespace) => `https://github.com/check/${namespace.replace(/-build$/, '')}.git`;

let clock = 0;
const EPOCH = Date.UTC(2026, 9, 9) / 1000;
// The time of a decision: long after every run the tests create, unless a test sets it.
const NOW = EPOCH + 100000 * 60;
const timestamp = (minute) => new Date((EPOCH + minute * 60) * 1000).toISOString().replace('.000Z', 'Z');
// Every run is created a minute after the one before, on a branch of its own unless it is given one.
// succeeded: 'True' and 'False' are finished, 'Unknown' is a run that waits for the quota or runs.
// commit is the push the run was created for: the parameter of the same name, a full SHA-1 of its own unless given.
// gitUrl is the remote of the push: the parameter git-url, the repository of the unit unless given.
const run = (namespace, {ci = true, succeeded, branch = `branch-${clock + 1}`, status, at, commit, gitUrl} = {}) => {
  const unit = namespace.replace(/-build$/, '');
  const minute = at ?? ++clock;
  return {
    metadata: {namespace, name: `${unit}-${ci ? 'ci' : 'release'}-${minute}-${Math.random().toString(16).slice(2, 7)}`,
      creationTimestamp: timestamp(minute),
      labels: ci ? {'image-builder.io/ci': unit} : {'image-builder.io/consumer': unit},
      annotations: branch === null ? {} : {'image-builder.io/ci-branch': branch}},
    spec: {pipelineRef: {name: `${unit}-${ci ? 'ci' : 'release'}`}, ...(status ? {status} : {}),
      params: [{name: 'commit', value: commit ?? minute.toString(16).padStart(40, 'c')}, {name: 'git-url', value: gitUrl ?? urlOf(namespace)}]},
    status: succeeded === undefined ? {} : {conditions: [{type: 'Succeeded', status: succeeded}]},
  };
};
const finished = (count, namespace, options = {}) => Array.from({length: count}, () => run(namespace, {succeeded: 'True', ...options}));
// A run that waits for a slot: created as the ci-push TriggerTemplate creates it.
const waiting = (namespace, options = {}) => run(namespace, {status: 'PipelineRunPending', succeeded: 'Unknown', ...options});
const running = (count, namespace) => Array.from({length: count}, () => run(namespace, {succeeded: 'Unknown'}));
// remote is what the keeper learned from the remotes: for each git-url it could read, the default branch and the
// `ci/` branches that exist there. mode is `decide` for the changes and `asks` for the remotes it needs to read first.
const decideWith = (program, items, max = MAX, {remote = {}, now = NOW, mode = 'decide'} = {}) => {
  const dir = mkdtempSync(join(tmpdir(), 'ci-run-keeper-jq-'));
  try {
    const file = join(dir, 'decision.jq');
    writeFileSync(file, program);
    writeFileSync(join(dir, 'remote.json'), JSON.stringify(remote));
    return execFileSync('jq', ['-c', '--argjson', 'max', String(max), '--argjson', 'now', String(now), '--arg', 'mode', mode,
      '--slurpfile', 'remote', join(dir, 'remote.json'), '-f', file], {input: JSON.stringify({items}), encoding: 'utf8'})
      .split('\n').filter(Boolean).map((line) => JSON.parse(line));
  } finally {
    rmSync(dir, {recursive: true, force: true});
  }
};
const PROGRAM = readFileSync(`${FILES}/ci-run-keeper.jq`, 'utf8');
const decide = (items, max = MAX, options) => decideWith(PROGRAM, items, max, options);
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
  const graceless = 'def cancelStatus: if isPending then "Cancelled" else "CancelledRunFinally" end;';
  assert.ok(PROGRAM.includes(graceless));
  assert.notDeepEqual(statuses(PROGRAM.replace(graceless, 'def cancelStatus: "Cancelled";'), [queued, started, newest]), expected,
    'PLANTED DEFECT: a keeper that cancels a started run outright leaves its commit status at pending');
});

// The note on a cancelled run is the push of the newest run of its branch: its commit and its run. A run that is
// replaced by a run that a third push replaces in turn names the third, never the one beside it.
const cancelledBy = (changes, run) => changes.find((c) => c.verb === 'cancel' && c.name === run.metadata.name)?.patch.metadata?.annotations?.['image-builder.io/cancelled-by'];

test('a replaced run names the newest push to its branch, whether it waited or had started', () => {
  const COMMIT = (letter) => letter.repeat(40);
  const queued = waiting('shop-build', {branch: 'main', commit: COMMIT('1')}), started = run('shop-build', {branch: 'main', succeeded: 'Unknown', commit: COMMIT('2')});
  const newest = run('shop-build', {branch: 'main', commit: COMMIT('3')});
  const changes = decide([newest, started, queued]);
  const by = `${COMMIT('3')} (${newest.metadata.name})`;
  assert.deepEqual([queued, started].map((r) => cancelledBy(changes, r)), [by, by]);
  assert.deepEqual(changes.filter((c) => c.verb === 'cancel').map((c) => c.say.split(', ').at(-1)), [by, by], 'the log line names it too');
  assert.equal(cancelledBy(changes, newest), undefined, 'the newest run is not cancelled and carries no note');
  const unaware = PROGRAM.replace('($newest[.metadata.namespace + "/" + branch] | pushOf) as $by', '(.metadata.name) as $by');
  assert.notEqual(unaware, PROGRAM, 'the planted defect finds its clause');
  assert.notEqual(cancelledBy(decideWith(unaware, [newest, started, queued]), started), by, 'PLANTED DEFECT: a note that names the cancelled run itself is caught');
  const nextOlder = PROGRAM.replace('sort_by(created, .metadata.name) | last | {key', 'sort_by(created, .metadata.name) | first | {key');
  assert.notEqual(nextOlder, PROGRAM, 'the planted defect finds its clause');
  assert.notEqual(cancelledBy(decideWith(nextOlder, [newest, started, queued]), queued), by, 'PLANTED DEFECT: a program that takes the oldest run of a branch for its newest names no push, and is caught');
});

test('planted innocent: pushes to two branches, and one branch in two build namespaces, cancel nothing and write no note', () => {
  const runs = [run('shop-build', {branch: 'main'}), run('shop-build', {branch: 'feature/x'}), run('post-build', {branch: 'main'}), waiting('shop-build', {branch: 'ci/issue-1-planted-1'})];
  assert.deepEqual(decide(runs).filter((c) => c.verb === 'cancel'), []);
  assert.ok(decide(runs).every((c) => !JSON.stringify(c.patch ?? {}).includes('cancelled-by')));
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

test('8 waiting runs of 8 units and none running start the 7 oldest, and the 8th waits with its reason', () => {
  const runs = namespaces(MAX + 1).map((namespace) => waiting(namespace));
  assert.deepEqual(started(runs), names(runs.slice(0, MAX)));
  const note = decide(runs).find((c) => c.type === 'merge');
  assert.equal(note.name, runs[MAX].metadata.name);
  assert.deepEqual(note.patch, {metadata: {annotations: {'image-builder.io/queued-behind': REASON}}});
  assert.deepEqual(decide(runs).map((c) => c.type), [...Array(MAX).fill('json'), 'merge'], 'starts come before notes');
});

test('7 running runs start none, and every waiting run waits with its reason', () => {
  const waits = [waiting('shop-build'), waiting('post-build')];
  assert.deepEqual(started([...running(MAX, 'shop-build'), ...waits]), []);
  assert.deepEqual(noted([...running(MAX, 'shop-build'), ...waits]), names(waits));
});

test('a free slot is a slot: 5 running runs and 3 waiting runs start the 2 oldest', () => {
  const waits = ['a-build', 'b-build', 'c-build'].map((namespace) => waiting(namespace));
  assert.deepEqual(started([...running(MAX - 2, 'post-build'), ...waits]), names(waits.slice(0, 2)));
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
  const cappedAtMax = (program) => {
    const runs = namespaces(MAX + 1).map((namespace) => waiting(namespace, {branch: null}));
    const starts = decideWith(program, runs).filter((c) => c.type === 'json');
    assert.equal(starts.length, MAX, `${starts.length} ci runs start at once`);
  };
  cappedAtMax(PROGRAM);
  assert.ok(PROGRAM.includes('[:$free]) as $startable'));
  assert.throws(() => cappedAtMax(PROGRAM.replace('[:$free]) as $startable', ') as $startable')), /8 ci runs start at once/);
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

test('7 waiting runs of 7 units all start, and a run of an 8th unit waits for a slot', () => {
  const seven = namespaces(MAX).map((namespace) => waiting(namespace)), eighth = waiting('late-build');
  assert.deepEqual(started([...seven, eighth]), names(seven));
  assert.equal(reasonOf(decide([...seven, eighth]), eighth), REASON);
  assert.equal(reasonOf(decide([...running(MAX, 'busy-build'), eighth]), eighth), REASON, 'a unit without a started run waits for a slot, not for itself');
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
    assert.match(calls[0], /^patch pipelinerun -n shop-build shop-ci-\S+ --type merge -p \{"spec":\{"status":"CancelledRunFinally"\},"metadata":\{"annotations":\{"image-builder.io\/cancelled-by":"[0-9a-f]{40} \(shop-ci-[^)]+\)"\}\}\}$/);
    assert.match(calls[1], /^delete pipelinerun -n shop-build shop-ci-\S+ --ignore-not-found --wait=false$/);
    assert.match(result.stdout, /deleted shop-build\//);
    // Only ci runs are listed: the decision is never taken on a release run.
    assert.match(readFileSync(`${log}.get`, 'utf8'), /^get --raw \/apis\/tekton\.dev\/v1\/pipelineruns\?labelSelector=image-builder\.io%2Fci&limit=50$/m);
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

// A stand-in kubectl that serves the planted runs as the API server pages a list: limit runs a page, and a
// continue token holding a "+", which reaches it intact only when the script encodes the token. FAIL_PAGE
// refuses that page, as an API server that times out would.
const PAGED_KUBECTL = `#!/usr/bin/env node
const fs = require('fs');
const args = process.argv.slice(2);
if (args[0] !== 'get') { fs.appendFileSync(process.env.LOG, args.join(' ') + '\\n'); process.exit(0); }
fs.appendFileSync(process.env.LOG + '.get', args.join(' ') + '\\n');
const url = new URL(args[2], 'https://api.invalid');
const token = url.searchParams.get('continue');
if (token !== null && !/^page\\+\\d+=$/.test(token)) { console.error('bad continue token: ' + token); process.exit(1); }
const from = token === null ? 0 : Number(token.slice(5, -1));
if (Number(process.env.FAIL_PAGE) === from / 50 + 1) { console.error('the server timed out'); process.exit(1); }
const items = JSON.parse(fs.readFileSync(process.env.RUNS, 'utf8')).items;
const to = from + Number(url.searchParams.get('limit'));
process.stdout.write(JSON.stringify({kind: 'PipelineRunList', metadata: to < items.length ? {continue: 'page+' + to + '='} : {}, items: items.slice(from, to)}));
`;
// A stand-in git that answers `ls-remote --symref <url> ...` from GIT_ANSWERS, a map from url to {stdout, stderr, status}, and
// writes down how it was called. Like git it asks a person for a login when it may prompt, and no person answers.
const GIT_STUB = `#!/usr/bin/env node
const fs = require('fs');
const args = process.argv.slice(2), env = process.env;
fs.appendFileSync(env.LOG + '.git', JSON.stringify({args, prompt: env.GIT_TERMINAL_PROMPT, protocol: env.GIT_ALLOW_PROTOCOL, locale: env.LC_ALL}) + '\\n');
if (env.GIT_TERMINAL_PROMPT !== '0') { console.error('git would ask a person for a login, and no person answers'); process.exit(99); }
const answer = JSON.parse(fs.readFileSync(env.GIT_ANSWERS, 'utf8'))[args[2]] ?? {status: 128, stderr: "fatal: repository '" + args[2] + "' not found\\n"};
process.stdout.write(answer.stdout ?? '');
process.stderr.write(answer.stderr ?? '');
process.exit(answer.status ?? 0);
`;
// A stand-in timeout that writes down the seconds it was given, and when TIMEOUT_FIRES is set ends as the BusyBox timeout of the
// keeper's image (alpine/k8s) does: by the SIGTERM it sends its command, which the shell reads as 143, not as the 124 of coreutils.
const TIMEOUT_STUB = `#!/usr/bin/env bash
echo "$1" >> "$LOG.timeout"
[ -z "\${TIMEOUT_FIRES:-}" ] || kill -TERM $$
shift
exec "$@"
`;
// The answer of a remote to `git ls-remote --symref <url> HEAD 'refs/heads/ci/*'`: its default branch and its `ci/` branches.
const listing = (defaultBranch, ...branches) => ({stdout: [`ref: refs/heads/${defaultBranch}\tHEAD`, `${'a'.repeat(40)}\tHEAD`,
  ...branches.map((name) => `${'b'.repeat(40)}\trefs/heads/${name}`)].join('\n') + '\n'});
const LOGIN = {status: 128, stderr: "fatal: could not read Username for 'https://github.com': terminal prompts disabled\n"};
const runPaged = (script, items, env = {}, lister = LISTER, {answers = {}} = {}) => {
  const bin = mkdtempSync(join(tmpdir(), 'ci-run-keeper-paged-'));
  try {
    const runs = join(bin, 'runs.json'), log = join(bin, 'log'), file = join(bin, 'ci-run-keeper.sh');
    writeFileSync(runs, JSON.stringify({items}));
    writeFileSync(log, '');
    writeFileSync(`${log}.git`, '');
    writeFileSync(`${log}.timeout`, '');
    writeFileSync(join(bin, 'answers.json'), JSON.stringify(answers));
    writeFileSync(join(bin, 'kubectl'), PAGED_KUBECTL);
    writeFileSync(join(bin, 'git'), GIT_STUB);
    writeFileSync(join(bin, 'timeout'), TIMEOUT_STUB);
    for (const tool of ['kubectl', 'git', 'timeout']) chmodSync(join(bin, tool), 0o755);
    writeFileSync(file, script);
    writeFileSync(join(bin, 'list-pipelineruns.sh'), lister);
    writeFileSync(join(bin, 'ci-run-keeper.jq'), PROGRAM);
    const result = spawnSync('bash', [file], {encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
      env: {...process.env, PATH: bin + ':' + process.env.PATH, RUNS: runs, LOG: log, KEEPER_DIR: bin, CI_MAX_RUNNING: String(MAX),
        GIT_ANSWERS: join(bin, 'answers.json'), ...env}});
    const lines = (path) => readFileSync(path, 'utf8').split('\n').filter(Boolean);
    return {...result, calls: lines(log), gets: lines(`${log}.get`), asked: lines(`${log}.git`).map((l) => JSON.parse(l)), bounds: lines(`${log}.timeout`)};
  } finally {
    rmSync(bin, {recursive: true, force: true});
  }
};
const SCRIPT = readFileSync(`${FILES}/ci-run-keeper.sh`, 'utf8');
const LISTER = readFileSync(`${FILES}/list-pipelineruns.sh`, 'utf8');
// A run as the API server returns it: the resolved pipeline in status.pipelineSpec (about 23 KB a run on
// master, nearly all of its size), task references, labels, annotations and conditions the decision never reads.
const pipelineSpec = {tasks: Array.from({length: 30}, (_, i) => ({name: `task-${i}`, taskSpec: {steps: [{name: 'run', image: 'alpine/k8s:1.35.6', script: 'x'.repeat(700)}]}}))};
const asServed = (r) => ({...r,
  metadata: {...r.metadata, uid: `uid-${r.metadata.name}`, labels: {...r.metadata.labels, 'tekton.dev/pipeline': 'ci'},
    annotations: {...r.metadata.annotations, 'image-builder.io/commit': 'a'.repeat(40)}},
  spec: {...r.spec, params: [...r.spec.params, {name: 'before', value: 'b'.repeat(40)}]},
  status: {...r.status, pipelineSpec, childReferences: [{name: `${r.metadata.name}-build`, pipelineTaskName: 'build'}],
    conditions: [...(r.status.conditions ?? []).map((c) => ({...c, reason: 'Running'})), {type: 'Ready', status: 'True'}]}});
// The steady state of today's 12 build namespaces and 20 more: each keeps 20 finished runs and has
// one more, with a replaced run, started runs, waiting runs and a note already written among them.
const steadyState = () => {
  const units = namespaces(32);
  const replacedRun = run(units[0], {branch: 'main', succeeded: 'Unknown'});
  return [
    ...units.flatMap((namespace) => finished(KEPT + 1, namespace)),
    ...finished(1, units[1], {succeeded: 'False'}),
    replacedRun, run(units[0], {branch: 'main', succeeded: 'Unknown'}),
    ...units.slice(2, 6).flatMap((namespace) => running(1, namespace)),
    waiting(units[6]), waiting(units[7]), waiting(units[8], {at: 0}),
    {...waiting(units[9]), metadata: {...waiting(units[9]).metadata, annotations: {'image-builder.io/queued-behind': REASON}}},
    // A waiting run of a branch that is deleted on its remote, and a run of one that is not.
    waiting(units[10], {branch: 'ci/gone'}), waiting(units[11], {branch: 'ci/live'}),
  ].map(asServed);
};
// What the remotes of the two runs above answer, as the keeper reads them and as git prints them.
const STEADY_REMOTE = {[urlOf('unit11-build')]: {default: 'master', branches: []}, [urlOf('unit12-build')]: {default: 'master', branches: ['ci/live']}};
const STEADY_ANSWERS = {[urlOf('unit11-build')]: listing('master'), [urlOf('unit12-build')]: listing('master', 'ci/live')};

test('the steady state of 32 build namespaces is listed raw, 50 runs a page, and decided as the full runs decide', () => {
  const items = steadyState();
  const expected = decide(items, MAX, {remote: STEADY_REMOTE});
  assert.deepEqual([...new Set(expected.map((c) => c.verb + (c.type ? ` ${c.type}` : '')))].sort(), ['cancel merge', 'delete', 'patch json', 'patch merge']);
  assert.equal(gone(expected).length, 1, 'the run of the deleted branch is among the changes');
  const result = runPaged(SCRIPT, items, {}, LISTER, {answers: STEADY_ANSWERS});
  assert.equal(result.status, 0, result.stderr);
  // The projection drops nothing the decision reads: the same changes come out, in the same order.
  assert.deepEqual(result.stdout.split('\n').filter(Boolean), expected.map((c) => c.say));
  assert.equal(result.calls.length, expected.length);
  assert.equal(result.gets.length, Math.ceil(items.length / 50));
  result.gets.forEach((get, page) => assert.equal(get, `get --raw /apis/tekton.dev/v1/pipelineruns?labelSelector=image-builder.io%2Fci&limit=50${page ? `&continue=page%2B${page * 50}%3D` : ''}`));
});

test('planted defects: a keeper that reads one page, drops spec.status, a param or sends the token unencoded goes red', () => {
  const items = steadyState();
  const expected = decide(items, MAX, {remote: STEADY_REMOTE}).map((c) => c.say);
  const variants = {
    'one page': [SCRIPT, LISTER.replace('[ -n "$continue_token" ] || return 0', 'return 0')],
    'no spec.status': [SCRIPT.replace('spec: {status: .spec.status, params:', 'spec: {params:'), LISTER],
    'no commit param': [SCRIPT.replace('select(.name == "commit" or .name == "git-url")', 'select(.name == "git-url")'), LISTER],
    'no git-url param': [SCRIPT.replace('select(.name == "commit" or .name == "git-url")', 'select(.name == "commit")'), LISTER],
    'unencoded token': [SCRIPT, LISTER.replace('.metadata.continue // "" | @uri', '.metadata.continue // ""')],
  };
  for (const [name, [script, lister]] of Object.entries(variants)) {
    assert.ok(script !== SCRIPT || lister !== LISTER, `${name}: the planted defect no longer applies to the keeper`);
    const result = runPaged(script, items, {}, lister, {answers: STEADY_ANSWERS});
    assert.ok(result.status !== 0 || result.stdout.split('\n').filter(Boolean).join('\n') !== expected.join('\n'), `${name} went unnoticed`);
  }
});

test('a page that fails fails the tick, and nothing is changed on part of the runs', () => {
  const result = runPaged(SCRIPT, steadyState(), {FAIL_PAGE: '3'});
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /the server timed out/);
  assert.deepEqual(result.calls, []);
  assert.equal(result.gets.length, 3);
});

// A `ci/` branch that is deleted on its remote sends no push, so no run ever tells the keeper: it asks the remote.
// The trigger admits a push of the default branch or of a `ci/` branch only, so a run of another branch is a run
// of the default branch, and the keeper judges no run of it. A branch is judged by the remote's answer for the
// git-url the run was created for: the default branch and the `ci/` branches that exist there.
const REMOTE_BRANCHES = ['ci/live-1', 'ci/live-2'];
const remoteOf = (namespace, branches = REMOTE_BRANCHES, defaultBranch = 'master') => ({[urlOf(namespace)]: {default: defaultBranch, branches}});
const asksOf = (items, options) => decide(items, MAX, {mode: 'asks', ...options});
const gone = (changes) => changes.filter((c) => c.verb === 'cancel' && c.patch.metadata.annotations['image-builder.io/branch-deleted'] !== undefined);
const sayOf = (changes) => changes.map((c) => `${c.verb} ${c.name}`);

test('the keeper asks the remote about the `ci/` branch of a run that has not finished, and about nothing else', () => {
  const queued = waiting('shop-build', {branch: 'ci/live-1'}), started = run('post-build', {branch: 'ci/gone', succeeded: 'Unknown'});
  assert.deepEqual(asksOf([queued, started]), [
    {ask: urlOf('post-build'), runs: [`post-build/${started.metadata.name}`]},
    {ask: urlOf('shop-build'), runs: [`shop-build/${queued.metadata.name}`]}]);
  // Two runs of one repository are one question.
  const second = waiting('shop-build', {branch: 'ci/gone'});
  assert.deepEqual(asksOf([queued, second]), [{ask: urlOf('shop-build'), runs: [queued, second].map((r) => `shop-build/${r.metadata.name}`).sort()}]);
});

test('planted innocent: the run of the default branch, a finished run, a run that is cancelled already, a run without a branch and a replaced run raise no question', () => {
  const ofDefault = [waiting('shop-build', {branch: 'master'}), run('post-build', {branch: 'main', succeeded: 'Unknown'}), waiting('shop-build', {branch: 'cinema'})];
  const done = run('shop-build', {branch: 'ci/x', succeeded: 'True'}), failed = run('shop-build', {branch: 'ci/x', succeeded: 'False'});
  const stopped = run('shop-build', {branch: 'ci/x', status: 'Cancelled'}), stopping = run('shop-build', {branch: 'ci/x', status: 'CancelledRunFinally', succeeded: 'Unknown'});
  const noBranch = waiting('shop-build', {branch: null});
  assert.deepEqual(asksOf([...ofDefault, done, failed, stopped, stopping, noBranch]), []);
  // The older run of a branch is cancelled by the newer one; the remote is asked for the newest only.
  const older = waiting('post-build', {branch: 'ci/y'}), newest = waiting('post-build', {branch: 'ci/y'});
  assert.deepEqual(asksOf([older, newest]), [{ask: urlOf('post-build'), runs: [`post-build/${newest.metadata.name}`]}]);
});

test('planted defect: a keeper that asks about the default branch, or about every open run, is caught', () => {
  const ofDefault = [waiting('shop-build', {branch: 'master'})];
  const clause = 'def isCiBranch: (branch // "") | startswith("ci/");';
  assert.ok(PROGRAM.includes(clause));
  assert.notDeepEqual(decideWith(PROGRAM.replace(clause, 'def isCiBranch: true;'), ofDefault, MAX, {mode: 'asks'}), [], 'PLANTED DEFECT: every branch is asked about');
  const open = 'select(isCiBranch and isOld)';
  assert.ok(PROGRAM.includes(open));
  const young = waiting('shop-build', {branch: 'ci/x', at: 5000});
  assert.notDeepEqual(decideWith(PROGRAM.replace(open, 'select(isCiBranch)'), [young], MAX, {mode: 'asks', now: EPOCH + 5000 * 60 + 30}), [], 'PLANTED DEFECT: a run of the first seconds is asked about');
});

test('a run is asked about from its 120th second, and not before', () => {
  const young = waiting('shop-build', {branch: 'ci/x', at: 700});
  const created = EPOCH + 700 * 60;
  assert.deepEqual(asksOf([young], {now: created + 119}), []);
  assert.deepEqual(asksOf([young], {now: created + 120}).map((a) => a.ask), [urlOf('shop-build')]);
});

test('a git-url that is not a GitHub clone url of an owner and a repository is refused and never asked', () => {
  const urls = ['', 'http://github.com/check/shop.git', 'https://github.com/check/shop', 'https://github.com/check/shop.git/extra',
    'https://evil.example/check/shop.git', 'https://github.com@evil.example/check/shop.git', 'ssh://git@github.com/check/shop.git',
    'https://github.com/check/shop.git --upload-pack=x', '-oProxyCommand=x'];
  for (const gitUrl of urls) {
    const bad = waiting('shop-build', {branch: 'ci/x', gitUrl});
    assert.deepEqual(asksOf([bad]), [{refuse: gitUrl, runs: [`shop-build/${bad.metadata.name}`]}], `refused: '${gitUrl}'`);
  }
  assert.deepEqual(asksOf([waiting('shop-build', {branch: 'ci/x', gitUrl: 'https://github.com/simetrixch/hostyour-cloud.git'})]).map((a) => a.ask), ['https://github.com/simetrixch/hostyour-cloud.git']);
  const check = 'def githubClone: test("^https://github[.]com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+[.]git$");';
  assert.ok(PROGRAM.includes(check));
  const unchecked = decideWith(PROGRAM.replace(check, 'def githubClone: true;'), [waiting('shop-build', {branch: 'ci/x', gitUrl: '-oProxyCommand=x'})], MAX, {mode: 'asks'});
  assert.deepEqual(unchecked.map((a) => a.ask), ['-oProxyCommand=x'], 'PLANTED DEFECT: a url that is no url is handed to git');
});

test('a run whose `ci/` branch is gone from its remote is cancelled outright when it waits, and gracefully when it has started, and carries the branch', () => {
  const queued = waiting('shop-build', {branch: 'ci/gone-1'}), started = run('shop-build', {branch: 'ci/gone-2', succeeded: 'Unknown'});
  const changes = decide([queued, started], MAX, {remote: remoteOf('shop-build')});
  assert.deepEqual(gone(changes).map((c) => [c.name, c.patch.spec.status, c.patch.metadata.annotations]).sort(), [
    [queued.metadata.name, 'Cancelled', {'image-builder.io/branch-deleted': 'ci/gone-1'}],
    [started.metadata.name, 'CancelledRunFinally', {'image-builder.io/branch-deleted': 'ci/gone-2'}]].sort());
  for (const c of gone(changes)) {
    assert.deepEqual([c.verb, c.type, c.namespace], ['cancel', 'merge', 'shop-build']);
    assert.match(c.say, new RegExp(`^cancelled shop-build/${c.name}: its branch ci/gone-[12] no longer exists on ${urlOf('shop-build')}$`));
  }
});

test('planted innocent: a run of a branch that exists, of the default branch, of a remote that was not read, or of the first minutes stays', () => {
  const live = [waiting('shop-build', {branch: 'ci/live-1'}), run('shop-build', {branch: 'ci/live-2', succeeded: 'Unknown'})];
  assert.deepEqual(gone(decide(live, MAX, {remote: remoteOf('shop-build')})), []);
  // The default branch of the remote is never cancelled, whatever it is called and however it is listed.
  const ofDefault = [waiting('shop-build', {branch: 'master'}), waiting('post-build', {branch: 'ci/trunk'})];
  assert.deepEqual(gone(decide(ofDefault, MAX, {remote: {...remoteOf('shop-build'), ...remoteOf('post-build', [], 'ci/trunk')}})), []);
  // A remote that was not read (a failed question, a repository that asks for a login) cancels nothing.
  assert.deepEqual(gone(decide([waiting('shop-build', {branch: 'ci/gone'})], MAX, {remote: remoteOf('post-build')})), []);
  assert.deepEqual(gone(decide([waiting('shop-build', {branch: 'ci/gone'})], MAX, {remote: {}})), []);
  // A run of the first two minutes is not asked about, so a branch that the remote has not listed yet is safe.
  const young = waiting('shop-build', {branch: 'ci/new', at: 900});
  assert.deepEqual(gone(decide([young], MAX, {remote: remoteOf('shop-build'), now: EPOCH + 900 * 60 + 119})), []);
  assert.deepEqual(gone(decide([young], MAX, {remote: remoteOf('shop-build'), now: EPOCH + 900 * 60 + 120})).map((c) => c.name), [young.metadata.name]);
  // A finished run, a run that is cancelled already and a run without a branch have nothing to end.
  const rest = [run('shop-build', {branch: 'ci/gone', succeeded: 'True'}), run('shop-build', {branch: 'ci/gone', status: 'Cancelled'}),
    run('shop-build', {branch: 'ci/gone', status: 'CancelledRunFinally', succeeded: 'Unknown'}), waiting('shop-build', {branch: null})];
  assert.deepEqual(gone(decide(rest, MAX, {remote: remoteOf('shop-build')})), []);
});

test('the same branch name in two repositories is judged by the remote of each run', () => {
  const shop = waiting('shop-build', {branch: 'ci/same'}), post = waiting('post-build', {branch: 'ci/same'});
  const remote = {...remoteOf('shop-build', []), ...remoteOf('post-build', ['ci/same'])};
  assert.deepEqual(gone(decide([shop, post], MAX, {remote})).map((c) => c.name), [shop.metadata.name]);
});

test('planted defect: a keeper that cancels a branch the remote still has, the default branch, or a run it did not read the remote of, is caught', () => {
  const live = waiting('shop-build', {branch: 'ci/live-1'}), ofDefault = waiting('post-build', {branch: 'ci/trunk'}), unread = waiting('late-build', {branch: 'ci/x'});
  const remote = {...remoteOf('shop-build'), ...remoteOf('post-build', [], 'ci/trunk')};
  const items = [live, ofDefault, unread];
  assert.deepEqual(gone(decide(items, MAX, {remote})), []);
  const notFound = '(.branches | index($branch)) == null';
  assert.ok(PROGRAM.includes(notFound));
  assert.notDeepEqual(gone(decideWith(PROGRAM.replace(notFound, 'true'), items, MAX, {remote})), [], 'PLANTED DEFECT: every run of a read remote is cancelled');
  const notDefault = '(.default != $branch) and ';
  assert.ok(PROGRAM.includes(notDefault));
  assert.notDeepEqual(gone(decideWith(PROGRAM.replace(notDefault, ''), items, MAX, {remote})), [], 'PLANTED DEFECT: the default branch is cancelled');
  const readOnly = '\n   | select(gitUrl as $url | $remoteBranches[$url] != null)';
  assert.ok(PROGRAM.includes(readOnly));
  assert.notDeepEqual(gone(decideWith(PROGRAM.replace(readOnly, ''), items, MAX, {remote})), [], 'PLANTED DEFECT: a remote that was not read is taken for one without branches');
});

test('the cancellation of a run whose branch is gone is graceful when it has started', () => {
  const queued = waiting('shop-build', {branch: 'ci/gone-1'}), started = run('shop-build', {branch: 'ci/gone-2', succeeded: 'Unknown'});
  const statuses = (program) => Object.fromEntries(gone(decideWith(program, [queued, started], MAX, {remote: remoteOf('shop-build')})).map((c) => [c.name, c.patch.spec.status]));
  const expected = {[queued.metadata.name]: 'Cancelled', [started.metadata.name]: 'CancelledRunFinally'};
  assert.deepEqual(statuses(PROGRAM), expected);
  assert.notDeepEqual(statuses(PROGRAM.replace('def cancelStatus: if isPending then "Cancelled" else "CancelledRunFinally" end;', 'def cancelStatus: "Cancelled";')), expected,
    'PLANTED DEFECT: a started run cancelled outright leaves its commit status at pending');
});

test('a waiting run whose branch is gone is never started and takes no slot, and the run of another unit starts in its place', () => {
  const goneRun = waiting('shop-build', {branch: 'ci/gone'}), other = waiting('post-build', {branch: 'ci/live-1'});
  const remote = {...remoteOf('shop-build'), ...remoteOf('post-build')};
  assert.deepEqual(started([goneRun, other], 1), names([goneRun]), 'without the remote the older run takes the one slot');
  const changes = decide([goneRun, other], 1, {remote});
  assert.deepEqual(changes.filter((c) => c.type === 'json').map((c) => c.name), [other.metadata.name]);
  assert.ok(!changes.some((c) => c.name === goneRun.metadata.name && c.verb !== 'cancel'), 'no note and no start on the run it cancels');
});

test('a run that a newer push replaces keeps the replaced cancellation, with no second patch for its deleted branch', () => {
  const older = waiting('shop-build', {branch: 'ci/gone'}), newest = waiting('shop-build', {branch: 'ci/gone'});
  const changes = decide([older, newest], MAX, {remote: remoteOf('shop-build')});
  const patches = changes.filter((c) => c.verb === 'cancel');
  assert.deepEqual(patches.map((c) => [c.name, Object.keys(c.patch.metadata.annotations)]), [
    [older.metadata.name, ['image-builder.io/cancelled-by']], [newest.metadata.name, ['image-builder.io/branch-deleted']]]);
});

test('the cancellations come before the starts, the notes and the deletions, the replaced ones first', () => {
  const older = waiting('shop-build', {branch: 'ci/live-1'}), newest = waiting('shop-build', {branch: 'ci/live-1'});
  const goneRun = waiting('post-build', {branch: 'ci/gone'});
  const other = waiting('other-build', {branch: 'ci/live-1'});
  const remote = {...remoteOf('shop-build'), ...remoteOf('post-build'), ...remoteOf('other-build')};
  const old = finished(KEPT + 1, 'other-build');
  const changes = decide([older, newest, goneRun, other, ...old], 1, {remote});
  assert.deepEqual(changes.map((c) => c.verb + (c.type ? ` ${c.type}` : '')), ['cancel merge', 'cancel merge', 'patch json', 'patch merge', 'delete']);
  assert.deepEqual(changes.slice(0, 2).map((c) => c.name), [older.metadata.name, goneRun.metadata.name]);
});

// The script asks each remote that the decision names, all at once, and hands the answers to the decision. A remote
// it cannot read is a remote it judges nothing of: a repository that asks for a login (a private one, or one that
// is gone) is said so and costs the tick nothing, because nothing the keeper does can read it; any other failure
// fails the tick, so that the CronJob shows it, and the other duties of the tick still run.
const ASKED = (url) => ({args: ['ls-remote', '--symref', url, 'HEAD', 'refs/heads/ci/*'], prompt: '0', protocol: 'https', locale: 'C'});
const patched = (result, needle) => result.calls.filter((call) => call.includes(needle));

test('the script asks each remote once, with no prompt, one protocol and ten seconds, and cancels the runs whose branch is gone', () => {
  const queued = waiting('shop-build', {branch: 'ci/gone'}), started = run('post-build', {branch: 'ci/gone-2', succeeded: 'Unknown'});
  const live = waiting('other-build', {branch: 'ci/live'}), second = waiting('shop-build', {branch: 'ci/gone-3'});
  const answers = {[urlOf('shop-build')]: listing('master', 'ci/live'), [urlOf('post-build')]: listing('master'), [urlOf('other-build')]: listing('master', 'ci/live')};
  const result = runPaged(SCRIPT, [queued, second, started, live], {}, LISTER, {answers});
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.asked.map((a) => a.args[2]).sort(), ['other-build', 'post-build', 'shop-build'].map(urlOf), 'one question for a repository of two runs');
  for (const asked of result.asked) assert.deepEqual(asked, ASKED(asked.args[2]));
  assert.deepEqual(result.bounds, ['10', '10', '10']);
  const cancels = patched(result, 'branch-deleted').sort();
  const expectedPatch = (name, status, branch) => new RegExp(`^patch pipelinerun -n \\S+ ${name} --type merge -p ${JSON.stringify({spec: {status}, metadata: {annotations: {'image-builder.io/branch-deleted': branch}}}).replace(/[{}[\]().*+?^$|\\]/g, '\\$&')}$`);
  assert.equal(cancels.length, 3);
  assert.ok(cancels.some((c) => expectedPatch(queued.metadata.name, 'Cancelled', 'ci/gone').test(c)), cancels.join('\n'));
  assert.ok(cancels.some((c) => expectedPatch(second.metadata.name, 'Cancelled', 'ci/gone-3').test(c)), cancels.join('\n'));
  assert.ok(cancels.some((c) => expectedPatch(started.metadata.name, 'CancelledRunFinally', 'ci/gone-2').test(c)), cancels.join('\n'));
  assert.match(result.stdout, new RegExp(`cancelled shop-build/${queued.metadata.name}: its branch ci/gone no longer exists on ${urlOf('shop-build').replaceAll('.', '\\.')}`));
});

test('planted innocent: a run of a branch that exists or of the default branch is left alone, and a tick with no `ci/` run asks nobody', () => {
  const live = waiting('shop-build', {branch: 'ci/live'}), ofDefault = waiting('post-build', {branch: 'master'});
  const result = runPaged(SCRIPT, [live, ofDefault], {}, LISTER, {answers: {[urlOf('shop-build')]: listing('master', 'ci/live')}});
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(patched(result, 'branch-deleted'), []);
  assert.deepEqual(result.asked.map((a) => a.args[2]), [urlOf('shop-build')], 'the repository of the default branch is not asked');
  const none = runPaged(SCRIPT, [ofDefault, ...finished(3, 'shop-build')]);
  assert.equal(none.status, 0, none.stderr);
  assert.deepEqual([none.asked, none.bounds], [[], []]);
});

test('a repository that asks for a login is said not to be judged, and costs the tick nothing', () => {
  const queued = waiting('shop-build', {branch: 'ci/x'});
  const result = runPaged(SCRIPT, [queued], {}, LISTER, {answers: {[urlOf('shop-build')]: LOGIN}});
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(patched(result, 'branch-deleted'), []);
  assert.match(result.stdout, new RegExp(`not judged: ${urlOf('shop-build').replaceAll('.', '\\.')} asks for a login, so no branch of it is read for shop-build/${queued.metadata.name}`));
  assert.equal(result.stderr, '');
});

const FAILURES = {
  'git did not answer in ten seconds': [{}, {TIMEOUT_FIRES: '1'}, /did not answer within 10 seconds/],
  'the network is down': [{status: 128, stderr: "fatal: unable to access 'https://github.com/check/shop.git/': Could not resolve host: github.com\n"}, {}, /Could not resolve host/],
  'git answers nothing': [{stdout: ''}, {}, /names no default branch/],
  'the answer names no default branch': [{stdout: `${'b'.repeat(40)}\trefs/heads/ci/live\n`}, {}, /names no default branch/],
};

test('a remote that cannot be read cancels nothing of its own, fails the tick, and the other duties of the tick still run', () => {
  for (const [what, [answer, env, message]] of Object.entries(FAILURES)) {
    const unread = waiting('shop-build', {branch: 'ci/gone'}), old = finished(KEPT + 1, 'post-build');
    const result = runPaged(SCRIPT, [unread, ...old], env, LISTER, {answers: {[urlOf('shop-build')]: answer}});
    assert.equal(result.status, 1, `${what}: the tick fails`);
    assert.match(result.stderr, new RegExp(`could not read the branches of ${urlOf('shop-build').replaceAll('.', '\\.')}`), what);
    assert.match(result.stderr, message, what);
    assert.deepEqual(patched(result, 'branch-deleted'), [], `${what}: the run is not cancelled on a guess`);
    assert.equal(patched(result, 'delete pipelinerun').length, 1, `${what}: the deletion of the finished run still runs`);
    assert.equal(patched(result, '--type json').length, 1, `${what}: the start of the waiting run still runs`);
  }
});

test('a remote that failed does not keep another remote from being read', () => {
  const unread = waiting('shop-build', {branch: 'ci/gone'}), read = waiting('post-build', {branch: 'ci/gone'});
  const result = runPaged(SCRIPT, [unread, read], {}, LISTER, {answers: {[urlOf('shop-build')]: {status: 128, stderr: 'fatal: the remote hung up\n'}, [urlOf('post-build')]: listing('master')}});
  assert.equal(result.status, 1);
  assert.deepEqual(patched(result, 'branch-deleted').map((c) => c.split(' ')[3]), ['post-build']);
});

test('a git-url that is no GitHub clone url is refused: it is never handed to git, and the tick fails', () => {
  const bad = waiting('shop-build', {branch: 'ci/x', gitUrl: '-oProxyCommand=x'});
  const result = runPaged(SCRIPT, [bad]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, new RegExp(`the git-url '-oProxyCommand=x' of shop-build/${bad.metadata.name} is not a GitHub clone url, so its branch is not read`));
  assert.deepEqual(result.asked, []);
});

test('planted defects: a script that may prompt, waits for ever, reads the end of its bound by the wrong status, takes any protocol, reads a bad answer as no branch, or hides a failure goes red', () => {
  const live = waiting('shop-build', {branch: 'ci/live'});
  const answers = {[urlOf('shop-build')]: listing('master', 'ci/live')};
  const gets = (script, extra = {}) => runPaged(script, [live], extra.env ?? {}, LISTER, {answers: extra.answers ?? answers});
  const baseline = gets(SCRIPT);
  assert.equal(baseline.status, 0, baseline.stderr);
  const mutate = (from, to) => { const script = SCRIPT.replaceAll(from, to); assert.notEqual(script, SCRIPT, `PLANTED DEFECT: the edit finds its clause: ${from}`); return script; };
  assert.equal(gets(mutate('GIT_TERMINAL_PROMPT=0 ', '')).status, 1, 'PLANTED DEFECT: git may ask a person for a login');
  assert.deepEqual(gets(mutate('timeout "$git_timeout" ', '')).bounds, [], 'PLANTED DEFECT: git has no time bound');
  const hung = {env: {TIMEOUT_FIRES: '1'}};
  assert.match(gets(SCRIPT, hung).stderr, /did not answer within 10 seconds/);
  assert.doesNotMatch(gets(mutate('git_timeout_status=143', 'git_timeout_status=124'), hung).stderr, /did not answer within 10 seconds/, 'PLANTED DEFECT: the bound is read by the status of coreutils, which the image of the keeper does not give');
  assert.notEqual(gets(mutate('GIT_ALLOW_PROTOCOL=https ', '')).asked[0].protocol, 'https', 'PLANTED DEFECT: git takes any protocol');
  assert.notEqual(gets(mutate('LC_ALL=C ', '')).asked[0].locale, 'C', 'PLANTED DEFECT: git answers in the language of the machine');
  const noHead = {[urlOf('shop-build')]: {stdout: ''}};
  assert.deepEqual(patched(gets(SCRIPT, {answers: noHead}), 'branch-deleted'), []);
  const readAsEmpty = gets(mutate('error("the answer names no default branch")', '{default: "", branches: []}'), {answers: noHead});
  assert.equal(patched(readAsEmpty, 'branch-deleted').length, 1, 'PLANTED DEFECT: an answer that names no default branch is read as a remote without branches');
  const failing = {[urlOf('shop-build')]: {status: 128, stderr: 'fatal: the remote hung up\n'}};
  assert.equal(gets(SCRIPT, {answers: failing}).status, 1);
  assert.equal(gets(mutate('failed=1', 'failed=0'), {answers: failing}).status, 0, 'PLANTED DEFECT: a failure that does not fail the tick');
});
