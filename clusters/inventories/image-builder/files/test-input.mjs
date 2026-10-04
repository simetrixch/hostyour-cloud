import {validateBinding} from './test-contract.mjs';

// This check runs before the credentialed clone. The registration and release
// grammar come from platform GitOps, while the URL/ref/SHA are event claims.
export function validateInput(registration, binding, releaseTagFilter) {
  validateBinding(binding, registration);
  if (binding.commit === "0".repeat(40)) throw new Error("deleted ref has no commit");
  const issue = /^refs\/heads\/issue-[1-9][0-9]{0,8}(?:-[A-Za-z0-9._-]+)?$/;
  const release = new RegExp('^refs/tags/(?:deploy/(?:dev|test|prod)/)?' + releaseTagFilter + '$');
  if (binding.ref !== 'refs/heads/' + registration.branch && !issue.test(binding.ref) && !release.test(binding.ref)) {
    throw new Error('ref is outside the registered issue/default-branch/release grammar');
  }
  return binding;
}

if (process.env.TEST_VALIDATE_INPUT === 'true') {
  validateInput(JSON.parse(process.env.TEST_REGISTRATION), {
    repositoryURL: process.env.TEST_REPOSITORY_URL, ref: process.env.TEST_REF,
    commit: process.env.TEST_COMMIT, recipeDigest: process.env.TEST_RECIPE_DIGEST,
    runnerDigest: process.env.TEST_RUNNER_DIGEST,
    pipelineRun: {name: process.env.TEST_RUN_NAME, namespace: process.env.TEST_RUN_NAMESPACE, uid: process.env.TEST_RUN_UID},
  }, process.env.TEST_RELEASE_TAG_FILTER);
}
