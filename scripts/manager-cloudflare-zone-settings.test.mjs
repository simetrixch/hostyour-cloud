import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {cpSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

// The Manager's second Cloudflare token, the one with Zone Settings Edit: the chart makes it a Secret of its own
// out of Vault <stage>/app/cloudflare-zone-settings, and hands it to the Manager Deployment alone, beside the DNS
// token and never in its place. No other inventory reads it, because cert-manager and the mail publishers need
// the DNS token only.
const INVENTORIES = 'clusters/inventories';
const renderChart = (chart, ...set) => execFileSync('helm', ['template', 'manager', chart, '--namespace', 'manager',
  '-f', 'clusters/platform/values-common.yaml', '-f', 'clusters/platform/values-prod.yaml',
  '-f', `${INVENTORIES}/manager/values-common.yaml`, '-f', `${INVENTORIES}/manager/values-prod.yaml`,
  '-f', 'scripts/standin/cluster-map.yaml', '-f', 'scripts/standin/installation-values.yaml',
  '--set', 'master.sshUser=ops', '--set', 'master.lanHost=10.0.0.1', '--set', 'onboarding.gatemanagerAddr=10.0.0.1',
  ...set.flatMap(value => ['--set', value])], {encoding: 'utf8'});
const yq = (rendered, expression) => execFileSync('yq', ['-o=json', '-I=0', expression, '-'], {input: rendered, encoding: 'utf8'}).trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
const environment = rendered => Object.fromEntries(yq(rendered, 'select(.kind == "Deployment" and .metadata.name == "manager") | .spec.template.spec.containers[0].env[]').map(entry => [entry.name, entry]));
const externalSecrets = rendered => yq(rendered, 'select(.kind == "ExternalSecret")');
const filesBelow = directory => readdirSync(directory, {recursive: true, withFileTypes: true}).filter(entry => entry.isFile())
  .map(entry => join(entry.parentPath, entry.name));

// Its Vault entry is absent while the answer is empty, and only deletionPolicy Delete keeps the ExternalSecret Ready then;
// the DNS token is required, so its entry is always there and its ExternalSecret has no such policy.
const ZONE_SETTINGS = {variable: 'CLOUDFLARE_ZONE_SETTINGS_API_TOKEN', secret: 'manager-cloudflare-zone-settings', entry: 'app/cloudflare-zone-settings', deletionPolicy: 'Delete'};
const DNS = {variable: 'CLOUDFLARE_DNS_API_TOKEN', secret: 'manager-cloudflare-dns', entry: 'app/cloudflare-dns'};
const TEMPLATE_ROW = /^CLOUDFLARE_ZONE_SETTINGS_API_TOKEN=$/gm;
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/** Every way the chart misses the settings token's way from Vault to the Manager, or lets another reader have it. */
function findings({rendered, stage, secretsTemplate, otherCharts}) {
  const found = [];
  const env = environment(rendered);
  for (const {variable, secret} of [ZONE_SETTINGS, DNS]) {
    if (!env[variable]) found.push(`the Manager Deployment passes no ${variable}`);
    else if (!same(env[variable].valueFrom?.secretKeyRef, {name: secret, key: 'api-token', optional: true})) found.push(`${variable} reads ${JSON.stringify(env[variable].valueFrom?.secretKeyRef ?? env[variable])}, not the optional api-token of ${secret}`);
  }
  const secrets = externalSecrets(rendered);
  for (const {secret, entry, deletionPolicy} of [ZONE_SETTINGS, DNS]) {
    const own = secrets.filter(each => each.metadata.name === secret);
    if (own.length !== 1) { found.push(`${own.length} ExternalSecrets named ${secret}`); continue; }
    if (own[0].spec.target.name !== secret) found.push(`ExternalSecret ${secret} makes the Secret ${own[0].spec.target.name}`);
    const data = own[0].spec.data.map(({secretKey, remoteRef}) => [secretKey, remoteRef.key, remoteRef.property]);
    if (!same(data, [['api-token', `${stage}/${entry}`, 'api-token']])) found.push(`ExternalSecret ${secret} reads ${JSON.stringify(data)}, not ${stage}/${entry} api-token alone`);
    if (own[0].spec.refreshPolicy !== 'OnChange') found.push(`ExternalSecret ${secret} refreshes by ${own[0].spec.refreshPolicy}, not on change`);
    if (own[0].spec.target.deletionPolicy !== deletionPolicy) found.push(`ExternalSecret ${secret} has deletionPolicy ${own[0].spec.target.deletionPolicy}, not ${deletionPolicy}`);
  }
  if (secretsTemplate.match(TEMPLATE_ROW)?.length !== 1) found.push(`the secrets template declares ${ZONE_SETTINGS.variable} ${secretsTemplate.match(TEMPLATE_ROW)?.length ?? 0} times, and the installer refuses a value for a key the template does not declare`);
  for (const [file, text] of Object.entries(otherCharts))
    if (text.includes(ZONE_SETTINGS.secret) || text.includes(ZONE_SETTINGS.variable) || text.includes(ZONE_SETTINGS.entry)) found.push(`${file} reads the settings token, which only the Manager holds`);
  return found;
}

const readOtherCharts = () => Object.fromEntries(readdirSync(INVENTORIES, {withFileTypes: true}).filter(entry => entry.isDirectory() && entry.name !== 'manager')
  .flatMap(entry => filesBelow(join(INVENTORIES, entry.name))).map(file => [file, readFileSync(file, 'utf8')]));
const input = {rendered: renderChart(`${INVENTORIES}/manager`), stage: 'prod', secretsTemplate: readFileSync('secrets/secrets.example', 'utf8'), otherCharts: readOtherCharts()};

test('the settings token reaches the Manager from its own Vault entry through its own Secret, beside the DNS token and no other reader', () => {
  assert.deepEqual(findings(input), []);
  assert.equal(environment(input.rendered)[ZONE_SETTINGS.variable].valueFrom.secretKeyRef.optional, true);
});

test('PLANTED INNOCENT: another stage reads the entry of its own stage', () => {
  assert.deepEqual(findings({...input, stage: 'test', rendered: renderChart(`${INVENTORIES}/manager`, 'global.env=test')}), []);
});

test('PLANTED DEFECT: a chart that swaps the two Secrets, drops the env, reads another entry or folds the token into the DNS Secret goes red', () => {
  const work = mkdtempSync(join(tmpdir(), 'zone-settings-chart-'));
  try {
    const mutations = {
      'the two Secret names swapped': {file: 'templates/deployment.yaml', change: text => text.replaceAll(ZONE_SETTINGS.secret, '@@').replaceAll(DNS.secret, ZONE_SETTINGS.secret).replaceAll('@@', DNS.secret)},
      'the env dropped': {file: 'templates/deployment.yaml', change: text => text.replace(new RegExp(`\\n\\s*- name: ${ZONE_SETTINGS.variable}\\n(?:\\s+(?:valueFrom|secretKeyRef|name|key|optional):[^\\n]*\\n?)+`), '\n')},
      'the env required': {file: 'templates/deployment.yaml', change: text => text.replace(new RegExp(`(name: ${ZONE_SETTINGS.secret}\\n\\s+key: api-token\\n\\s+)optional: true`), '$1optional: false')},
      'a wrong Vault path': {file: 'templates/externalsecret-cloudflare-zone-settings.yaml', change: text => text.replace(`"%s/${ZONE_SETTINGS.entry}"`, `"%s/${DNS.entry}"`)},
      'no deletionPolicy Delete': {file: 'templates/externalsecret-cloudflare-zone-settings.yaml', change: text => text.replace('    deletionPolicy: Delete\n', '')},
      'a Secret of another name': {file: 'templates/externalsecret-cloudflare-zone-settings.yaml', change: text => text.replace(/(target:\n\s+name: )manager-cloudflare-zone-settings/, '$1manager-cloudflare-dns')},
    };
    for (const [name, {file, change}] of Object.entries(mutations)) {
      const chart = join(work, name.replaceAll(' ', '-'));
      cpSync(`${INVENTORIES}/manager`, chart, {recursive: true});
      const source = readFileSync(join(chart, file), 'utf8');
      const mutant = change(source);
      assert.notEqual(mutant, source, `${name} must change the chart`);
      writeFileSync(join(chart, file), mutant);
      assert.notDeepEqual(findings({...input, rendered: renderChart(chart)}), [], name);
    }
  } finally {
    rmSync(work, {recursive: true, force: true});
  }
});

test('PLANTED DEFECT: a secrets template without the row and another inventory that reads the token go red', () => {
  assert.notDeepEqual(findings({...input, secretsTemplate: input.secretsTemplate.replace(TEMPLATE_ROW, '')}), []);
  assert.notDeepEqual(findings({...input, secretsTemplate: `${input.secretsTemplate}\nCLOUDFLARE_ZONE_SETTINGS_API_TOKEN=\n`}), []);
  const [file] = Object.keys(input.otherCharts).filter(name => name.includes('cert-manager-account'));
  assert.notDeepEqual(findings({...input, otherCharts: {...input.otherCharts, [file]: `${input.otherCharts[file]}\n# ${ZONE_SETTINGS.secret}\n`}}), []);
});
