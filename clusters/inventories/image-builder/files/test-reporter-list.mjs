import {getParam, isCommit} from './test-contract.mjs';

// Bounded pagination must finish before its caller can use a partial list.
export async function listRuns(request, namespace) {
  const items = [];
  const tokens = new Set();
  let next = '';
  for (let page = 0; page < 100; page++) {
    const path = '/apis/tekton.dev/v1/namespaces/' + namespace + '/pipelineruns' +
      '?labelSelector=hostyour.cloud%2Ftest-managed%3Dtrue&limit=100' + (next ? '&continue=' + encodeURIComponent(next) : '');
    const listing = await request(path);
    if (!Array.isArray(listing.items)) throw new Error('invalid PipelineRun listing');
    items.push(...listing.items);
    next = listing.metadata?.continue ?? '';
    if (!next) return items;
    if (typeof next !== 'string' || tokens.has(next)) throw new Error('invalid PipelineRun continuation');
    tokens.add(next);
  }
  throw new Error('PipelineRun listing exceeded reconciliation bound');
}

export async function listGithub(request, path, field) {
  const items = [];
  for (let page = 1; page <= 20; page++) {
    const reply = await request(path + (path.includes('?') ? '&' : '?') + 'per_page=100&page=' + page);
    const values = field ? reply[field] : reply;
    if (!Array.isArray(values) || values.length > 100) throw new Error('invalid GitHub listing');
    items.push(...values);
    if (values.length < 100) return items;
  }
  throw new Error('GitHub listing exceeded reconciliation bound');
}

export function latestRun(runs, registration, commit, ref) {
  if (!isCommit(commit) || commit === '0'.repeat(40) || typeof ref !== 'string' || ref.length > 256) throw new Error('invalid latest-run query');
  const matches = runs.filter(run => getParam(run, 'git-url') === registration.repositoryURL &&
    getParam(run, 'commit') === commit && getParam(run, 'ref') === ref);
  for (const run of matches) if (!Number.isFinite(Date.parse(run.metadata.creationTimestamp))) throw new Error('invalid run creation time');
  matches.sort((a, b) => b.metadata.creationTimestamp.localeCompare(a.metadata.creationTimestamp));
  if (matches.length > 1 && matches[0].metadata.creationTimestamp === matches[1].metadata.creationTimestamp) throw new Error('ambiguous latest run');
  return matches[0];
}
