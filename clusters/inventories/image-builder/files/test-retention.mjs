import {condition} from './test-contract.mjs';

export function expiredTestRun(run, registration, now) {
  const completed = Date.parse(run.status?.completionTime ?? '');
  return run.metadata.namespace === registration.name + '-build' &&
    run.metadata.labels?.['hostyour.cloud/test-managed'] === 'true' &&
    run.spec.pipelineRef?.name === registration.name + '-tests' && !run.spec.pipelineRef.resolver && !run.spec.pipelineSpec &&
    ['True', 'False'].includes(condition(run)?.status) && Number.isFinite(completed) &&
    now - completed >= 14 * 24 * 60 * 60 * 1000;
}
