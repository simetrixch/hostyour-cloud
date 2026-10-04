import {digest, condition, getParam, getResult, validateBinding, validateResult, emptyResult} from './test-contract.mjs';
const ownedBy = (object, uid) => object.metadata.ownerReferences?.some(owner => owner.uid === uid && owner.controller === true);

function checkTask(task, run, name, registration, runnerDigest, nodeImage) {
  const reference = task.spec.taskRef;
  const params = Object.fromEntries((reference?.params ?? []).map(param => [param.name, param.value]));
  if (!ownedBy(task, run.metadata.uid) || reference?.resolver !== 'cluster' || params.namespace !== 'image-builder' ||
      params.kind !== 'task' || params.name !== name || task.metadata.labels?.['tekton.dev/pipelineRun'] !== run.metadata.name) {
    throw new Error('TaskRun is not the expected trusted task');
  }
  if (name === 'test-suites') {
    const step = task.status?.taskSpec?.steps?.find(value => value.name === 'runner');
    if (!step && !task.status?.taskSpec && condition(task)?.status !== 'True' && condition(task)?.status !== 'False') return;
    if (!step || step.image !== nodeImage || digest(step.args?.[2] ?? '') !== runnerDigest ||
        getParam(task, 'recipe-json') !== JSON.stringify(registration) || getParam(task, 'run-id') !== run.metadata.uid) {
      throw new Error('suite runner or recipe identity changed');
    }
  }
}

export function bindRun(run, registration, runnerDigest) {
  if (run.metadata.namespace !== registration.name + '-build' || run.spec.pipelineRef?.name !== registration.name + '-tests' ||
      run.spec.pipelineRef?.resolver || run.spec.pipelineSpec || getParam(run, 'git-url') !== registration.repositoryURL) {
    throw new Error('unmanaged PipelineRun identity');
  }
  const binding = {repositoryURL: registration.repositoryURL, ref: getParam(run, 'ref'), commit: getParam(run, 'commit'),
    recipeDigest: registration.recipeDigest, runnerDigest,
    pipelineRun: {name: run.metadata.name, namespace: run.metadata.namespace, uid: run.metadata.uid}};
  validateBinding(binding, registration);
  return binding;
}

export async function inspect(run, registration, runnerDigest, nodeImage, getTask) {
  const binding = bindRun(run, registration, runnerDigest);
  const children = run.status?.childReferences ?? [];
  const states = new Map();
  for (const [pipelineTask, taskName] of [['clone', 'git-clone'], ['scan', 'credential-scan'],
    ['dependencies', 'test-dependencies'], ['tests', 'test-suites']]) {
    const refs = children.filter(child => child.pipelineTaskName === pipelineTask && child.kind === 'TaskRun');
    if (refs.length > 1) throw new Error('ambiguous TaskRun evidence');
    if (!refs.length) continue;
    const task = await getTask(run.metadata.namespace, refs[0].name);
    checkTask(task, run, taskName, registration, runnerDigest, nodeImage);
    states.set(pipelineTask, task);
  }
  const terminal = condition(run)?.status === 'False';
  const suite = states.get('tests');
  const failedTask = [...states.values()].some(task => condition(task)?.status === 'False');
  if (!terminal && !failedTask && condition(suite ?? {})?.status !== 'True') return {binding};
  const startedAt = run.status?.startTime ?? run.metadata.creationTimestamp;
  const completedAt = run.status?.completionTime ?? suite?.status?.completionTime ?? condition(run)?.lastTransitionTime ?? startedAt;
  const clone = states.get('clone');
  const deps = states.get('dependencies');
  const prerequisites = ['clone', 'scan', 'dependencies'].every(name => condition(states.get(name) ?? {})?.status === 'True') &&
    getResult(clone ?? {}, 'commit') === binding.commit && getResult(clone ?? {}, 'url') === binding.repositoryURL &&
    getResult(deps ?? {}, 'recipe-digest') === binding.recipeDigest;
  const runnerFinished = condition(suite ?? {})?.status === 'True' &&
    suite.status.steps?.find(step => step.name === 'runner')?.terminated?.exitCode === 0;
  let result;
  let passed = false;
  if (prerequisites && getResult(suite ?? {}, 'result-json') && !terminal) {
    result = JSON.parse(getResult(suite, 'result-json') ?? 'null');
    passed = validateResult(result, binding, registration);
    if (passed && !runnerFinished) throw new Error('positive receipt has no successful runner exit');
  } else {
    const reason = condition(run)?.reason ?? condition(suite ?? {})?.reason ?? 'MissingRequiredEvidence';
    const canceled = /cancel/i.test(reason);
    result = emptyResult(binding, registration, canceled ? 'canceled' : 'infrastructure-failed',
      'authoritative run did not complete required evidence: ' + reason, startedAt, completedAt);
  }
  validateResult(result, binding, registration);
  return {binding, result, passed};
}

