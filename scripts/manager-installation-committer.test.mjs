import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {cpSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';

// The mailbox an installation's commits carry. hostyour-deploy writes it as `installationCommitterEmail` into the installation's
// installation/values/manager.yaml from its committer_email answer (ansiwise/templates/manager-values.tpl, bound by a row of
// ansiwise/programs/deploy-branch.yaml). This chart hands it to the Manager container as INSTALLATION_COMMITTER_EMAIL where it is supplied
// and renders nothing where it is not, so a Manager given no mailbox still publishes and refuses a placement. The chart's default is empty,
// and no per-stage file repeats a mailbox.
//
// THE TEMPLATE AND THE ROW ARE READ AT THE COMMIT ci-sources.json PINS, out of the hostyour-deploy clone beside the main checkout,
// the way scripts/check.sh reads the rows that render clusters/bootstrap. The generated file is made here from them, never typed here:
// a fixture typed in this test would stay green while the key in hostyour-deploy drifts.
const ROOT = fileURLToPath(new URL('..', import.meta.url));
const INVENTORIES = 'clusters/inventories';
const MANAGER_CHART = `${INVENTORIES}/manager`;
const STAGES = ['dev', 'test', 'prod'];
const VARIABLE = 'INSTALLATION_COMMITTER_EMAIL';
const VALUE_KEY = 'installationCommitterEmail';
const ANSWER = 'committer_email';
const TEMPLATE_PATH = 'ansiwise/templates/manager-values.tpl';
const PROGRAM_PATH = 'ansiwise/programs/deploy-branch.yaml';
const SLOT = /<([a-z][a-z0-9-]*)>/g;
// What the program's answers are in this test. Each answer has a value of its own, so a slot bound to the wrong answer reads wrong.
const ANSWERS = {operator_user: 'ops', lan_host: '10.0.0.1', programs_repo: 'check-owner/check-programs', committer_email: 'installation@example.invalid', committer_name: 'Other Answer'};

const yq = (text, expression) => execFileSync('yq', ['-o=json', '-I=0', expression, '-'], {input: text, encoding: 'utf8', cwd: ROOT}).trim().split('\n').filter(Boolean).map(line => JSON.parse(line));

function deployClone() {
  const pin = yq(readFileSync(join(ROOT, 'ci-sources.json'), 'utf8'), '.git["hostyour-deploy"]')[0];
  assert.match(pin, /^[0-9a-f]{40}$/, `ci-sources.json pins hostyour-deploy at '${pin}', not a full commit`);
  const common = resolve(ROOT, execFileSync('git', ['-C', ROOT, 'rev-parse', '--git-common-dir'], {encoding: 'utf8'}).trim());
  const source = resolve(common, '..', '..', 'hostyour-deploy');
  const read = path => {
    try {
      return execFileSync('git', ['-C', source, 'show', `${pin}:${path}`], {encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']});
    } catch (error) {
      throw new Error(`hostyour-deploy ${path} at ${pin.slice(0, 7)}, the pin of ci-sources.json, could not be read from ${source} — clone simetrixch/hostyour-deploy beside the main checkout and fetch that commit: ${error.stderr}`);
    }
  };
  return {template: read(TEMPLATE_PATH), program: read(PROGRAM_PATH)};
}

/** The row of the program that writes the template, and the names of the answers the program asks. */
function readProgram(program) {
  const rows = yq(program, `.steps[] | select(.template == "${TEMPLATE_PATH}")`);
  assert.equal(rows.length, 1, `${rows.length} rows of ${PROGRAM_PATH} write ${TEMPLATE_PATH}, not one`);
  return {row: rows[0], answers: yq(program, '.answers[].name')};
}

/** Every way the template, the row and the program's answers fail to hand the installation's mailbox to installation/values/manager.yaml. */
function generate({template, row, answers}) {
  const faults = [];
  const bound = row.values ?? {};
  const slots = [...new Set([...template.matchAll(SLOT)].map(match => match[1]))];
  for (const slot of slots) if (!bound[slot]) faults.push(`<${slot}> of the template has no binding in the row`);
  for (const slot of Object.keys(bound)) if (!slots.includes(slot)) faults.push(`the row binds ${slot}, which the template has no slot for`);
  for (const [slot, {answer}] of Object.entries(bound)) if (!answers.includes(answer)) faults.push(`${slot} is bound to ${answer}, which the program does not ask`);
  const file = template.replace(SLOT, (slot, name) => ANSWERS[bound[name]?.answer] ?? slot);
  const mailbox = yq(file, `.${VALUE_KEY} // ""`)[0];
  if (mailbox !== ANSWERS[ANSWER]) faults.push(`${VALUE_KEY} of the generated file is '${mailbox}', not the ${ANSWER} answer '${ANSWERS[ANSWER]}'`);
  return {file, faults};
}

const renderChart = (chart, stage, generated, ...set) => execFileSync('helm', ['template', 'manager', chart, '--namespace', 'manager',
  '-f', 'clusters/platform/values-common.yaml', '-f', `clusters/platform/values-${stage}.yaml`,
  '-f', `${chart}/values-common.yaml`, '-f', `${chart}/values-${stage}.yaml`,
  ...(generated ? ['-f', generated] : []),
  '-f', 'scripts/standin/cluster-map.yaml',
  ...set.flatMap(value => ['--set', value])], {encoding: 'utf8', cwd: ROOT});

function* walk(node, path) {
  yield {path: path.join('.'), node};
  if (node && typeof node === 'object') for (const [key, child] of Object.entries(node)) yield* walk(child, [...path, key]);
}
const documents = rendered => yq(rendered, '.').filter(Boolean).flatMap(doc => [...walk(doc, [`${doc.kind}/${doc.metadata?.name}`])]);

/** Every way a render misses the mailbox on the Manager container, or lets another container or object have it. `mailbox` is undefined where none was supplied. */
function renderFindings({rendered, mailbox}) {
  const found = [];
  const nodes = documents(rendered);
  const entries = nodes.filter(({node}) => node?.name === VARIABLE);
  if (mailbox === undefined) {
    for (const {path} of entries) found.push(`${path} sets ${VARIABLE} though no mailbox was supplied`);
    return found;
  }
  const own = /^Deployment\/manager\.spec\.template\.spec\.containers\.0\.env\.\d+$/;
  if (!entries.some(({path}) => own.test(path))) found.push(`the Manager container has no ${VARIABLE}, though ${mailbox} was supplied`);
  for (const {path, node} of entries) {
    if (!own.test(path)) found.push(`${path} sets ${VARIABLE}, which only the Manager container reads`);
    else if (JSON.stringify(node) !== JSON.stringify({name: VARIABLE, value: mailbox})) found.push(`${path} is ${JSON.stringify(node)}, not the supplied mailbox as a plain value`);
  }
  for (const {path, node} of nodes) if (typeof node === 'string' && node.includes(mailbox) && !own.test(path.replace(/\.value$/, ''))) found.push(`${path} carries the mailbox`);
  return found;
}

const filesBelow = directory => readdirSync(directory, {recursive: true, withFileTypes: true}).filter(entry => entry.isFile()).map(entry => join(entry.parentPath, entry.name));

/** Every way the chart's own files, or another inventory's, carry the setting where it must not stand. */
function chartFindings({chart, otherCharts}) {
  const found = [];
  const common = readFileSync(resolve(ROOT, chart, 'values-common.yaml'), 'utf8');
  const standing = yq(common, `.${VALUE_KEY}`)[0];
  if (standing === undefined || standing === null) found.push(`values-common.yaml does not state ${VALUE_KEY}, so the key has no place in the chart's values`);
  else if (standing !== '') found.push(`values-common.yaml gives ${VALUE_KEY} the default '${standing}', a mailbox nobody gave`);
  for (const stage of STAGES) if (readFileSync(resolve(ROOT, chart, `values-${stage}.yaml`), 'utf8').includes(VALUE_KEY)) found.push(`values-${stage}.yaml repeats ${VALUE_KEY}, which the installation's own file carries`);
  for (const [file, text] of Object.entries(otherCharts)) if (text.includes(VALUE_KEY) || text.includes(VARIABLE)) found.push(`${file} reads the mailbox, which only the Manager holds`);
  return found;
}

const readOtherCharts = () => Object.fromEntries(readdirSync(join(ROOT, INVENTORIES), {withFileTypes: true}).filter(entry => entry.isDirectory() && entry.name !== 'manager')
  .flatMap(entry => filesBelow(join(ROOT, INVENTORIES, entry.name))).map(file => [file, readFileSync(file, 'utf8')]));

const deploy = deployClone();
const program = readProgram(deploy.program);
const generation = generate({template: deploy.template, row: program.row, answers: program.answers});
const work = mkdtempSync(join(tmpdir(), 'manager-committer-'));
test.after(() => rmSync(work, {recursive: true, force: true}));
const write = (name, text) => { const path = join(work, name); writeFileSync(path, text); return path; };
const generated = write('manager.yaml', generation.file);
const without = write('manager-without.yaml', generation.file.replace(new RegExp(`^${VALUE_KEY}:.*\\n`, 'm'), ''));
const emptyAnswer = write('manager-empty.yaml', generation.file.replace(new RegExp(`^${VALUE_KEY}:.*\\n`, 'm'), `${VALUE_KEY}:\n`));
const mailbox = ANSWERS[ANSWER];

test('the template, its row and the program hand the committer_email answer to the generated Manager values', () => {
  assert.deepEqual(generation.faults, []);
});

test('PLANTED INNOCENT: a mailbox supplied reaches the Manager container alone, on every stage', () => {
  for (const stage of STAGES) assert.deepEqual(renderFindings({rendered: renderChart(MANAGER_CHART, stage, generated), mailbox}), [], stage);
});

test('PLANTED INNOCENT: a mailbox absent, or an empty answer, renders no environment entry, on every stage', () => {
  for (const stage of STAGES) {
    assert.deepEqual(renderFindings({rendered: renderChart(MANAGER_CHART, stage, without)}), [], `${stage} without the key`);
    assert.deepEqual(renderFindings({rendered: renderChart(MANAGER_CHART, stage, emptyAnswer)}), [], `${stage} with an empty answer`);
  }
});

test('the chart gives the setting an empty default, no stage file repeats it and no other inventory reads it', () => {
  assert.deepEqual(chartFindings({chart: MANAGER_CHART, otherCharts: readOtherCharts()}), []);
});

test('PLANTED DEFECT: a row without the binding, with another answer or with an answer the program does not ask, and a template with another key, go red', () => {
  const faulty = {
    'the binding dropped': {row: {...program.row, values: Object.fromEntries(Object.entries(program.row.values).filter(([slot]) => slot !== 'committer-email'))}, expect: /<committer-email> of the template has no binding/},
    'another answer bound': {row: {...program.row, values: {...program.row.values, 'committer-email': {answer: 'committer_name'}}}, expect: /not the committer_email answer/},
    'an answer the program does not ask': {row: {...program.row, values: {...program.row.values, 'committer-email': {answer: 'committer_mailbox'}}}, expect: /committer_mailbox, which the program does not ask/},
    'a stale binding': {row: {...program.row, values: {...program.row.values, 'old-slot': {answer: 'committer_email'}}}, expect: /old-slot, which the template has no slot for/},
    'another key in the template': {template: deploy.template.replace(`${VALUE_KEY}:`, 'installationCommiterEmail:'), expect: /of the generated file is ''/},
    'no key in the template': {template: deploy.template.replace(new RegExp(`^${VALUE_KEY}:.*\\n`, 'm'), ''), expect: /of the generated file is ''/},
  };
  for (const [name, {expect, ...change}] of Object.entries(faulty)) {
    const {faults} = generate({template: deploy.template, row: program.row, answers: program.answers, ...change});
    assert.ok(faults.some(fault => expect.test(fault)), `${name}: ${JSON.stringify(faults)}`);
  }
});

test('PLANTED DEFECT: a chart that reads another key, names another variable, renders an empty value, invents a default or repeats a mailbox per stage goes red', () => {
  const mutations = {
    'another key read': {file: 'templates/deployment.yaml', change: text => text.replace(`.Values.${VALUE_KEY}`, '.Values.installationCommiterEmail'), expect: /the Manager container has no INSTALLATION_COMMITTER_EMAIL/},
    'another variable name': {file: 'templates/deployment.yaml', change: text => text.replace(`name: ${VARIABLE}`, 'name: INSTALLATION_COMMITER_EMAIL'), expect: /the Manager container has no INSTALLATION_COMMITTER_EMAIL/},
    'rendered when empty': {file: 'templates/deployment.yaml', change: text => text.replace(`{{- with .Values.${VALUE_KEY} }}`, '{{- if true }}').replace(/(name: INSTALLATION_COMMITTER_EMAIL\n\s+value: )\{\{ \. \| quote \}\}/, `$1{{ .Values.${VALUE_KEY} | quote }}`), expect: /sets INSTALLATION_COMMITTER_EMAIL though no mailbox was supplied/},
    'a default mailbox': {file: 'values-common.yaml', change: text => text.replace(new RegExp(`^${VALUE_KEY}:.*$`, 'm'), `${VALUE_KEY}: "default@example.invalid"`), expect: /gives installationCommitterEmail the default 'default@example.invalid'/},
    'a mailbox in a stage file': {file: 'values-prod.yaml', change: text => `${text}\n${VALUE_KEY}: "stage@example.invalid"\n`, expect: /values-prod.yaml repeats installationCommitterEmail/},
  };
  for (const [name, {file, change, expect}] of Object.entries(mutations)) {
    const chart = join(work, name.replaceAll(' ', '-'));
    cpSync(join(ROOT, MANAGER_CHART), chart, {recursive: true});
    const source = readFileSync(join(chart, file), 'utf8');
    const mutant = change(source);
    assert.notEqual(mutant, source, `${name} must change the chart`);
    writeFileSync(join(chart, file), mutant);
    const found = [...renderFindings({rendered: renderChart(chart, 'prod', generated), mailbox}), ...renderFindings({rendered: renderChart(chart, 'prod', without)}), ...chartFindings({chart, otherCharts: {}})];
    assert.ok(found.some(finding => expect.test(finding)), `${name}: ${JSON.stringify(found)}`);
  }
});

test('PLANTED DEFECT: a mailbox on another container, in another object, or from a secret goes red', () => {
  const rendered = renderChart(MANAGER_CHART, 'prod', generated);
  const edit = expression => execFileSync('yq', ['-e', expression, '-'], {input: rendered, encoding: 'utf8'});
  const manager = 'select(.kind == "Deployment" and .metadata.name == "manager")';
  const planted = {
    'also set on an init container': {rendered: edit(`(${manager} | .spec.template.spec.initContainers[0].env) += [{"name": "${VARIABLE}", "value": "${mailbox}"}]`), expect: /initContainers\.0\.env\.\d+ sets INSTALLATION_COMMITTER_EMAIL, which only the Manager container reads/},
    'moved to an init container': {rendered: edit(`(${manager} | .spec.template.spec.containers[0].env) |= map(select(.name != "${VARIABLE}")) | (${manager} | .spec.template.spec.initContainers[0].env) += [{"name": "${VARIABLE}", "value": "${mailbox}"}]`), expect: /the Manager container has no INSTALLATION_COMMITTER_EMAIL/},
    'copied into a ConfigMap': {rendered: `${rendered}\n---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: copy\ndata:\n  mailbox: ${mailbox}\n`, expect: /ConfigMap\/copy\.data\.mailbox carries the mailbox/},
    'read from a secret': {rendered: edit(`(${manager} | .spec.template.spec.containers[0].env[] | select(.name == "${VARIABLE}")) = {"name": "${VARIABLE}", "valueFrom": {"secretKeyRef": {"name": "x", "key": "y"}}}`), expect: /not the supplied mailbox as a plain value/},
  };
  for (const [name, {rendered: mutant, expect}] of Object.entries(planted)) {
    const found = renderFindings({rendered: mutant, mailbox});
    assert.ok(found.some(finding => expect.test(finding)), `${name}: ${JSON.stringify(found)}`);
  }
});
