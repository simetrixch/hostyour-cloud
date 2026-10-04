import {readFileSync} from 'node:fs';
import {kubernetes, withRequestDeadline} from './test-reporter-api.mjs';
import {listRuns} from './test-reporter-list.mjs';
import {expiredTestRun} from './test-retention.mjs';
import {redact} from './test-contract.mjs';

const registrations = JSON.parse(readFileSync('/pruner-code/registrations.json', 'utf8'));
let failed = false;
for (const registration of registrations) {
  if (registration.name === 'digita-catalog-show') continue;
  const namespace = registration.name + '-build';
  try {
    await withRequestDeadline(120000, async () => {
      for (const run of await listRuns(kubernetes, namespace)) {
        if (!expiredTestRun(run, registration, Date.now())) continue;
        await kubernetes('/apis/tekton.dev/v1/namespaces/' + namespace + '/pipelineruns/' + run.metadata.name, 'DELETE', {
          apiVersion: 'v1', kind: 'DeleteOptions', propagationPolicy: 'Foreground',
          preconditions: {uid: run.metadata.uid, resourceVersion: run.metadata.resourceVersion},
        });
        console.log('expired test run ' + namespace + '/' + run.metadata.name);
      }
    });
  } catch (error) {failed = true; console.error('retention retry needed for ' + namespace + ': ' + redact(error.message));}
}
if (failed) process.exitCode = 1;
