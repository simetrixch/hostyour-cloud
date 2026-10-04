import {readFileSync, mkdirSync, writeFileSync, readdirSync, statSync, rmSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {createServer} from 'node:http';
import {digest, condition, getParam, getResult, emptyResult, redact, validateBinding, validateResult} from './test-contract.mjs';
import {bindRun, inspect} from './test-reporter-evidence.mjs';
import {github, kubernetes, validateReporterIdentity, withRequestDeadline} from './test-reporter-api.mjs';
import {readState, writeState, historicalReceipt} from './test-reporter-state.mjs';
import {listRuns, listGithub, latestRun} from './test-reporter-list.mjs';

const registrations = JSON.parse(readFileSync('/reporter-code/registrations.json', 'utf8'));
const registry = new Map(registrations.map(value => [value.name + '-build', value]));
const runnerDigest = process.env.TEST_RUNNER_DIGEST;
const stateDirectory = '/reporter-state';
mkdirSync(stateDirectory + '/locks', {recursive: true});
const runPath = (namespace, name) => '/apis/tekton.dev/v1/namespaces/' + namespace + '/pipelineruns' + (name ? '/' + name : '');
const taskPath = (namespace, name) => '/apis/tekton.dev/v1/namespaces/' + namespace + '/taskruns/' + name;

async function withLock(key, action) {
  const directory = stateDirectory + '/locks/' + key;
  try {mkdirSync(directory);} catch (error) {if (error.code === 'EEXIST') return; throw error;}
  const owner = randomUUID();
  writeFileSync(directory + '/owner', owner, {mode: 0o600});
  try {return await action();}
  finally {
    try {if (readFileSync(directory + '/owner', 'utf8') === owner) rmSync(directory, {recursive: true});}
    catch (error) {if (error.code !== 'ENOENT') throw error;}
  }
}


async function publish(run, registration) {
  // Only a valid repository/SHA/UID binding may create a check. Invalid task
  // evidence on such a run must produce a new failure, never preserve old success.
  const binding = bindRun(run, registration, runnerDigest);
  const key = digest(binding.repositoryURL + '\n' + binding.commit + '\n' + binding.pipelineRun.uid).slice(7);
  return withLock(key, () => withRequestDeadline(90000, async () => {
    const path = stateDirectory + "/" + key + ".json";
    const cached = readState(path);
    let evidence;
    try {
      run = await kubernetes(runPath(binding.pipelineRun.namespace, binding.pipelineRun.name));
      if (JSON.stringify(bindRun(run, registration, runnerDigest)) !== JSON.stringify(binding)) throw new Error('run binding changed during publication');
      // A runner/recipe rollout must not rewrite completed historical checks.
      // Release lookup still requires the current digests, and a later failure
      // or cancellation always re-enters authoritative reconciliation.
      const historical = historicalReceipt(cached, run, binding);
      if (historical) return historical;
      evidence = await inspect(run, registration, runnerDigest, process.env.TEST_NODE_IMAGE,
      (namespace, name) => kubernetes(taskPath(namespace, name)));
    }
    catch (error) {
      const startedAt = run.status?.startTime ?? run.metadata.creationTimestamp;
      const completedAt = run.status?.completionTime ?? condition(run)?.lastTransitionTime ?? startedAt;
      evidence = {binding, passed: false, completed: true, result: emptyResult(binding, registration, 'infrastructure-failed',
        'trusted evidence rejected: ' + redact(error.message).slice(0, 400), startedAt, completedAt)};
    }
    let {result, passed, completed} = evidence;
    if (cached?.receipt && !result) {
      result = emptyResult(binding, registration, 'infrastructure-failed', 'completed evidence became pending',
        cached.receipt.result.startedAt, cached.receipt.result.completedAt);
      passed = false;
      completed = true;
    }
    if (result) passed = validateResult(result, binding, registration);
    const fingerprint = digest(JSON.stringify({binding, result, passed, completed}));
    if (cached?.fingerprint === fingerprint) return cached.receipt;
    const base = '/repos/digitaplatform/' + registration.name;
    const found = await listGithub(github, base + '/commits/' + binding.commit + '/check-runs?check_name=tekton%2Ftests&filter=all', 'check_runs');
    const matches = found.filter(check => String(check.app?.id) === process.env.REPORTER_APP_ID &&
      check.head_sha === binding.commit && check.external_id === binding.pipelineRun.uid) ?? [];
    if (matches.length > 2) throw new Error('Checks result exceeded reconciliation bound');
    const detailsURL = process.env.TEST_LOG_URL + '/#/namespaces/' + binding.pipelineRun.namespace + '/pipelineruns/' + binding.pipelineRun.name;
    const body = {name: 'tekton/tests', head_sha: binding.commit, external_id: binding.pipelineRun.uid,
      status: completed ? 'completed' : 'in_progress', details_url: detailsURL};
    if (completed) {
      body.conclusion = passed ? 'success' : result.result === 'canceled' ? 'cancelled' : 'failure';
      body.completed_at = result.completedAt;
      body.output = {title: passed ? 'Required suites passed' : 'Required suite proof failed', summary: JSON.stringify(result),
        text: 'Trusted recipe ' + binding.recipeDigest + '; runner ' + runnerDigest + '.\nIssue proof: pending'};
    } else body.started_at = run.status?.startTime ?? run.metadata.creationTimestamp;
    let checks;
    if (!matches.length) checks = [await github(base + '/check-runs', 'POST', body)];
    else {
      checks = [];
      for (const match of matches) {
        if (!completed && match.status === 'completed') throw new Error('completed check has no terminal authoritative evidence');
        if (completed && match.output?.summary === JSON.stringify(result) && match.output?.text?.includes('Issue proof: sent')) body.output.text = match.output.text;
        const {head_sha, name, ...update} = body;
        checks.push(await github(base + '/check-runs/' + match.id, 'PATCH', update));
      }
    }
    if (!completed) {
      const receipt = result ? {binding, passed, result, completed: false} : undefined;
      writeState(path, {fingerprint, completedAt: run.metadata.creationTimestamp, receipt});
      return receipt;
    }
    const issue = /^refs\/heads\/issue-([1-9][0-9]{0,8})(?:-|$)/.exec(binding.ref)?.[1];
    if (issue && !checks.some(check => check.output?.text?.includes('Issue proof: sent'))) {
      const target = await github(base + '/issues/' + issue);
      if (!target.html_url?.startsWith('https://github.com/digitaplatform/' + registration.name + '/issues/')) throw new Error('issue belongs to another repository');
      const marker = '<!-- tekton-tests:' + binding.pipelineRun.uid + ' -->';
      const comments = await listGithub(github, base + '/issues/' + issue + '/comments');
      const existing = comments.find(comment => comment.user?.login === 'digita-tekton-reporter[bot]' && comment.body?.includes(marker));
      const proof = marker + '\nTrusted tekton/tests: ' + result.result + ' at ' + binding.commit + '.\n' +
        detailsURL + '\n```json\n' + JSON.stringify(result) + '\n```';
      if (!existing) await github(base + '/issues/' + issue + '/comments', 'POST', {body: proof});
      else if (existing.body !== proof) await github(base + '/issues/comments/' + existing.id, 'PATCH', {body: proof});
    }
    for (const check of checks) if (!check.output?.text?.includes('Issue proof: sent')) {
      await github(base + '/check-runs/' + check.id, 'PATCH', {output: {...body.output,
        text: body.output.text.replace('Issue proof: pending', 'Issue proof: sent')}});
    }
    const receipt = {binding, passed, result, completed: true};
    // Persist only after Checks and the issue proof have both been published.
    writeState(path, {fingerprint, completedAt: result.completedAt, receipt});
    return receipt;
  }));
}

let scanning;
async function reconcile() {
  if (scanning) return scanning;
  scanning = (async () => {
    const errors = [];
    // Namespace discovery is independent. A cycle and each publication have
    // wall-clock deadlines; a failed CronJob surfaces exhausted retries.
    await Promise.all([...registry].map(async ([namespace, registration]) => {
      try {
        await withRequestDeadline(140000, async () => {
          const runs = await listRuns(kubernetes, namespace);
          for (const run of runs) {
            if (Date.now() - Date.parse(run.status?.completionTime ?? run.metadata.creationTimestamp) > 14 * 24 * 60 * 60 * 1000) continue;
            await publish(run, registration);
          }
        });
      } catch (error) {errors.push(namespace); console.error('reporter retry needed for ' + namespace + ': ' + redact(error.message));}
    }));
    for (const name of readdirSync(stateDirectory + '/locks')) {
      const path = stateDirectory + '/locks/' + name;
      // Every API call times out in15seconds. A full publication is bounded
      // well below ten minutes; an older lock belongs to a dead process.
      try {
        if (Date.now() - statSync(path).mtimeMs > 10 * 60 * 1000) rmSync(path, {recursive: true});
      } catch (error) {if (error.code !== 'ENOENT') throw error;}
    }
    for (const name of readdirSync(stateDirectory).filter(name => /^[a-f0-9]{64}\.json$/.test(name))) {
      const path = stateDirectory + '/' + name;
      const record = readState(path);
      if (record && Date.now() - Date.parse(record.completedAt) > 14 * 24 * 60 * 60 * 1000) rmSync(path, {force: true});
    }
    for (const name of readdirSync(stateDirectory).filter(name => /^[a-f0-9]{64}\.json\.[a-f0-9-]+\.tmp$/.test(name))) {
      const path = stateDirectory + '/' + name;
      try {
        if (Date.now() - statSync(path).mtimeMs > 14 * 24 * 60 * 60 * 1000) rmSync(path, {force: true});
      } catch (error) {if (error.code !== 'ENOENT') throw error;}
    }
    if (errors.length) throw new Error('reporter reconciliation failed in ' + errors.length + ' namespaces');
  })();
  try {await scanning;} finally {scanning = undefined;}
}

await validateReporterIdentity();
if (process.argv.includes('--once')) await reconcile();
else {
  createServer(async (request, response) => {
    if (request.method !== 'GET') {response.writeHead(405).end(); return;}
    if (request.url === '/readyz') {response.writeHead(200).end('ready'); return;}
    const url = new URL(request.url, 'http://reporter');
    const match = /^\/receipts\/([a-z0-9-]+-build)\/([a-z0-9-]+)\/([a-f0-9-]+)$/.exec(url.pathname);
    const latest = /^\/latest\/([a-z0-9-]+-build)\/([a-f0-9]{40})$/.exec(url.pathname);
    const namespace = (match ?? latest)?.[1];
    if (!registry.has(namespace)) {response.writeHead(404).end(); return;}
    try {
      const registration = registry.get(namespace);
      let run;
      if (latest) {
        const runs = await withRequestDeadline(30000, () => listRuns(kubernetes, namespace));
        run = latestRun(runs, registration, latest[2], url.searchParams.get('ref'));
        if (!run) {response.writeHead(202).end(JSON.stringify({pending: true})); return;}
      } else {
        run = await kubernetes(runPath(namespace, match[2]));
        if (run.metadata.uid !== match[3]) {response.writeHead(409).end(); return;}
      }
      const receipt = await publish(run, registration);
      if (latest && receipt && (receipt.binding.runnerDigest !== runnerDigest || receipt.binding.recipeDigest !== registration.recipeDigest)) {
        response.writeHead(409).end(); return;
      }
      if (latest && receipt?.completed) {
        const newest = latestRun(await withRequestDeadline(30000, () => listRuns(kubernetes, namespace)), registration, latest[2], url.searchParams.get('ref'));
        if (newest?.metadata.uid !== run.metadata.uid) {response.writeHead(202).end(JSON.stringify({pending: true})); return;}
      }
      const pending = !receipt || (latest && !receipt.completed);
      response.writeHead(pending ? 202 : 200, {'Content-Type': 'application/json'}).end(JSON.stringify(pending ? {pending: true} : receipt));
    } catch (error) {
      console.error('reporter request failed: ' + redact(error.message));
      response.writeHead(503).end();
    }
  }).listen(Number(process.env.REPORTER_PORT), '0.0.0.0');
  await reconcile().catch(error => console.error(redact(error.message)));
  setInterval(() => reconcile().catch(error => console.error('reporter reconciliation failed: ' + redact(error.message))), 30000);
}
