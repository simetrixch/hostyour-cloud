import test from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {renderChart} from './render-chart.mjs';
import {execute, numbered, withFailure} from './ci-report-harness.mjs';

// What Alertmanager does with the alert that the report task of the ci pipeline posts: which route takes
// it, how it is grouped, and the mail it becomes. The charts are rendered here; the alert is the one the
// script posts (scripts/ci-report-harness.mjs); the mail is rendered by scripts/mail-eval with the template
// engines Alertmanager uses. The route walk below is a model of the configuration the Prometheus operator
// builds, and it is the only part of this file that is not run by Alertmanager's own code.

const docs = renderChart('observability', ['--api-versions', 'monitoring.coreos.com/v1alpha1']);
const configs = Object.fromEntries(docs.filter((d) => d.kind === 'AlertmanagerConfig').map((d) => [d.metadata.name, d]));
const secret = docs.find((d) => d.kind === 'Secret' && d.metadata.name === 'alertmanager-observability-alertmanager');
const fromSecret = (key) => Buffer.from(secret.data[key], 'base64').toString('utf8');
const baseConfig = JSON.parse(execFileSync('yq', ['-o=json', '.'], {input: fromSecret('alertmanager.yaml'), encoding: 'utf8'}));

const LOG = ['npm ERR! <script>alert("pwned")</script>', 'expected "a" & got <b>b</b>', 'at file.js:10'].join('\n');
const posted = (() => {
  const result = execute({taskRuns: withFailure('check'), logs: {'shop-ci-abc12-ci-pod': LOG + '\n'}});
  assert.equal(result.status, 0, result.stderr);
  return result.alerts[0][0];
})();

// The routes the operator builds: the routes of the base configuration first, none of them continuing, then
// the first-level route of each AlertmanagerConfig, which continues (strategy None adds no namespace matcher,
// observability/values-common.yaml alertmanagerConfigMatcherStrategy). The receiver of a route that matches
// nothing is the root's.
const matcherHolds = ({name, matchType = '=', value}, labels) => {
  const actual = labels[name] ?? '';
  return {'=': actual === value, '!=': actual !== value, '=~': new RegExp(`^(?:${value})$`).test(actual), '!~': !new RegExp(`^(?:${value})$`).test(actual)}[matchType];
};
const parseBaseMatcher = (text) => { const [, name, matchType, value] = /^(\w+)\s*(=~|!~|!=|=)\s*"?(.*?)"?$/.exec(text); return {name, matchType, value}; };
const receiversFor = (labels, amConfigs = configs) => {
  const routes = [...baseConfig.route.routes.map((r) => ({receiver: r.receiver, matchers: r.matchers.map(parseBaseMatcher), continue: false})),
    ...Object.keys(amConfigs).sort().map((name) => ({receiver: amConfigs[name].spec.route.receiver, matchers: amConfigs[name].spec.route.matchers ?? [], continue: true}))];
  const reached = [];
  for (const route of routes) {
    if (route.matchers.every((m) => matcherHolds(m, labels))) {
      reached.push(route.receiver);
      if (!route.continue) break;
    }
  }
  return reached.length ? reached : [baseConfig.route.receiver];
};
const mailsTo = (labels, amConfigs = configs) => receiversFor(labels, amConfigs).filter((receiver) =>
  Object.values(amConfigs).some((c) => c.spec.receivers.some((r) => r.name === receiver && r.emailConfigs?.length)));

test('a failed ci run is mailed once, by its own route, and every other alert keeps its mail', () => {
  assert.deepEqual(mailsTo(posted.labels), ['ci-run-failed'], 'PLANTED INNOCENT: the labels the script posts reach the ci route and no other');
  assert.deepEqual(mailsTo({alertname: 'KubePodCrashLooping', severity: 'warning', namespace: 'shop'}), ['platform-default']);
  assert.deepEqual(mailsTo({alertname: 'Watchdog', severity: 'none'}), [], 'the Watchdog is mailed by no route');
  assert.deepEqual(mailsTo({alertname: 'InfoOnly', severity: 'info'}), []);

  const without = structuredClone(configs);
  without['platform-default'].spec.route.matchers = without['platform-default'].spec.route.matchers.filter((m) => m.value !== 'CIRunFailed');
  assert.deepEqual(mailsTo(posted.labels, without), ['ci-run-failed', 'platform-default'], 'PLANTED DEFECT: without the negative matcher the run is mailed twice');
  const needsLabel = structuredClone(configs);
  needsLabel['ci-run-failed'].spec.route.matchers.push({name: 'service', matchType: '=', value: 'ci'});
  assert.deepEqual(mailsTo(posted.labels, needsLabel), [], 'PLANTED DEFECT: a matcher on a label the alert does not carry mails nothing');
  const misspelled = structuredClone(configs);
  misspelled['ci-run-failed'].spec.route.matchers[0].value = 'CIRunFailure';
  assert.deepEqual(mailsTo(posted.labels, misspelled), [], 'PLANTED DEFECT: a misspelled alert name mails nothing');
});

test('one red run is one group and one mail: grouped by run, 5 seconds of waiting, no mail at its end', () => {
  const route = configs['ci-run-failed'].spec.route;
  assert.deepEqual(route.groupBy, ['alertname', 'repository', 'branch', 'commit']);
  assert.ok(route.groupBy.every((name) => name in posted.labels), 'every label the group is named by is on the posted alert');
  assert.equal(route.groupWait, '5s');
  const seconds = (text) => Number(/^(\d+)([smh])$/.exec(text)[1]) * {s: 1, m: 60, h: 3600}[/^(\d+)([smh])$/.exec(text)[2]];
  const lifetime = (Date.parse(posted.endsAt) - Date.parse(posted.startsAt)) / 1000;
  assert.ok(seconds(route.repeatInterval) > 10 * lifetime, 'a firing alert is not mailed again before it ends');
  assert.ok(seconds(route.groupInterval) <= 600, 'a resolution is recorded soon after the alert ends, so a later failure of the same commit is a new mail');
  const mail = configs['ci-run-failed'].spec.receivers[0].emailConfigs;
  assert.ok(mail.length >= 1 && mail.every((c) => c.sendResolved === false && c.to), 'PLANTED INNOCENT: the end of the alert mails nothing, and the mail has a recipient');
  assert.ok(configs['platform-default'].spec.receivers[0].emailConfigs.every((c) => c.sendResolved === true), 'the resolved mail of every other alert stays');
  const resolvedMail = structuredClone(configs['ci-run-failed']);
  resolvedMail.spec.receivers[0].emailConfigs[0].sendResolved = true;
  assert.ok(!resolvedMail.spec.receivers[0].emailConfigs.every((c) => c.sendResolved === false), 'PLANTED DEFECT: a receiver that sends resolved mails a second time');
  // Two branches at one commit are two runs and two mails; a group without the branch would merge them.
  const groupOf = (groupBy, labels) => JSON.stringify(groupBy.map((name) => labels[name] ?? ''));
  const otherBranch = {...posted.labels, branch: 'main'};
  assert.notEqual(groupOf(route.groupBy, posted.labels), groupOf(route.groupBy, otherBranch), 'PLANTED INNOCENT: the branch tells the groups apart');
  assert.equal(groupOf(['alertname', 'repository', 'commit'], posted.labels), groupOf(['alertname', 'repository', 'commit'], otherBranch), 'PLANTED DEFECT: a group without the branch merges two branches');
});

const data = (alerts) => ({receiver: 'ci-run-failed', status: 'firing', alerts: alerts.map((a) => ({status: 'firing', ...a})),
  groupLabels: {alertname: 'CIRunFailed'}, commonLabels: Object.fromEntries(['alertname', 'repository', 'branch', 'commit'].map((k) => [k, alerts[0].labels[k]])),
  commonAnnotations: {}, externalURL: 'https://alertmanager.example.test'});
const renders = (list, templates = {'ci.tmpl': fromSecret('ci.tmpl')}) => execFileSync('go', ['run', '.'], {cwd: 'scripts/mail-eval', encoding: 'utf8',
  input: JSON.stringify({templates, renders: list})}).split('\n').filter(Boolean).map((line) => JSON.parse(line));
const emailConfig = configs['ci-run-failed'].spec.receivers[0].emailConfigs[0];
const subjectTemplate = emailConfig.headers.find((h) => h.key === 'Subject').value;

test('the mail carries the repository, the branch, the commit, the subject, the author, the failed task and step, the log and both links', () => {
  const [subject, text, html] = renders([{text: subjectTemplate, data: data([posted])}, {text: emailConfig.text, data: data([posted])},
    {text: emailConfig.html, html: true, data: data([posted])}]);
  for (const result of [subject, text, html]) assert.equal(result.error, '', result.error);
  assert.equal(subject.out, 'CI red: shop feature/vat a1b2c3d');
  const fields = [posted.labels.repository, posted.labels.branch, posted.labels.commit, posted.annotations.subject, posted.annotations.author,
    posted.annotations.failure, posted.annotations.run_url, posted.annotations.logs_url];
  for (const field of fields) assert.ok(text.out.includes(field), `the text carries ${field}`);
  assert.ok(text.out.includes(posted.annotations.log), 'the text carries the log as it is');
  const unescaped = html.out.replaceAll('&amp;', '&').replaceAll('&#34;', '"').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&#39;', "'");
  for (const field of fields.filter((f) => !f.startsWith('https://'))) assert.ok(html.out.includes(field.replaceAll('&', '&amp;')) || unescaped.includes(field), `the html carries ${field}`);
  assert.ok(html.out.includes(`href="${posted.annotations.run_url}"`), 'the first link');
  assert.match(html.out, /href="https:\/\/grafana\.example\.test\/explore\?schemaVersion=1&amp;orgId=1&amp;panes=%7B/, 'the second link, with its parameters intact');
  // The order of a reader: the commit, the failure, the log, then the links.
  const order = ['Repository:', 'Branch:', 'Commit:', 'Subject:', 'Author:', 'Failed:', 'Log:', 'Run:', 'Logs:'].map((label) => text.out.indexOf(label));
  assert.ok(order.every((at, i) => at >= 0 && (i === 0 || at > order[i - 1])), `the text reads in order: ${order}`);
});

test('the html part escapes the log, a repository\'s own output, and sets it in a monospace block', () => {
  const [html] = renders([{text: emailConfig.html, html: true, data: data([posted])}]);
  assert.equal(html.error, '');
  assert.ok(!html.out.includes('<script>') && !html.out.includes('<b>b</b>'), 'PLANTED INNOCENT: no markup of the log reaches the html');
  assert.ok(html.out.includes('&lt;script&gt;alert(&#34;pwned&#34;)&lt;/script&gt;') && html.out.includes('expected &#34;a&#34; &amp; got &lt;b&gt;b&lt;/b&gt;'));
  assert.match(html.out, /<pre style="[^"]*monospace[^"]*">npm ERR! &lt;script&gt;/);
  // A template can only bypass the escaping through Alertmanager's safeHtml, which the stand-in does not register.
  const unsafe = fromSecret('ci.tmpl').replace('{{ .Annotations.log }}', '{{ .Annotations.log | safeHtml }}');
  assert.notEqual(unsafe, fromSecret('ci.tmpl'));
  assert.throws(() => renders([{text: emailConfig.html, html: true, data: data([posted])}], {'ci.tmpl': unsafe}), /safeHtml/,
    'PLANTED DEFECT: a log marked safe is refused by the stand-in, so it cannot pass this test');
});

test('a failure and the problem of reading it are two blocks of one mail, and an annotation that is missing reads as empty', () => {
  const second = {...posted, labels: {...posted.labels, task: 'report-failure', step: 'none'},
    annotations: {...posted.annotations, failure: 'report-failure, step none: GET the log of ci answered HTTP 500', log: 'the log of ci could not be read'}};
  const [text] = renders([{text: emailConfig.text, data: data([posted, second])}]);
  assert.equal(text.error, '');
  assert.ok(text.out.includes(posted.annotations.failure) && text.out.includes(second.annotations.failure) && text.out.includes('the log of ci could not be read'));
  const bare = {labels: posted.labels, annotations: {}};
  const [empty] = renders([{text: emailConfig.text, data: data([bare])}]);
  assert.equal(empty.error, '', 'a missing annotation is empty and not an error');
  assert.ok(!empty.out.includes('<no value>'));
});

test('the ci mail templates are defined for the receiver and the others keep the alert templates', () => {
  assert.deepEqual(['ci.subject', 'ci.text', 'ci.html'].map((name) => fromSecret('ci.tmpl').includes(`{{- define "${name}" -}}`)), [true, true, true]);
  assert.deepEqual([subjectTemplate, emailConfig.text, emailConfig.html], ['{{ template "ci.subject" . }}', '{{ template "ci.text" . }}', '{{ template "ci.html" . }}']);
  const other = configs['platform-default'].spec.receivers[0].emailConfigs[0];
  assert.deepEqual([other.headers[0].value, other.text, other.html], ['{{ template "alert.subject" . }}', '{{ template "alert.text" . }}', '{{ template "alert.html" . }}']);
  assert.ok(fromSecret('alert.tmpl').includes('define "alert.subject"'), 'the template map still holds the alert templates beside the ci templates');
  // A receiver that names a template nobody defined renders an error, not a mail.
  const [missing] = renders([{text: '{{ template "ci.unknown" . }}', data: data([posted])}]);
  assert.match(missing.error, /ci\.unknown/);
});

// The sender of every alert mail, and the relay that signs it. A receiver passes SPF and DKIM for a mail only when
// the domain it is sent from has an SPF record for the egress and a key the relay signs with. The relay prepares one key
// file per domain it admits (clusters/inventories/postfix/values-common.yaml), and hostyour-deploy writes that allowlist
// as the platform domain and the unit apex (ansiwise/templates/postfix-values.tpl); both come from the cluster map, as
// does the domain the cluster is reached under. The three differ on every installation, so the stand-in's one value for
// all three cannot tell them apart, and each stage below gets three names of its own.
const STAGES = ['dev', 'test', 'prod'];
const domainsOf = (stage) => ({domain: `cluster.${stage}.invalid`, platformDomain: `platform.${stage}.invalid`, unitApex: `apex.${stage}.invalid`});
const setsOf = (stage, {domain, platformDomain, unitApex}) => ['--set', `global.env=${stage}`, '--set', `global.domain=${domain}`,
  '--set', `global.platformDomain=${platformDomain}`, '--set', `global.unitApex=${unitApex}`];
const smtpFromOf = (stage, domains) => {
  const rendered = renderChart('observability', ['--api-versions', 'monitoring.coreos.com/v1alpha1', ...setsOf(stage, domains)]);
  const alertmanager = rendered.find((d) => d.kind === 'Secret' && d.metadata.name === 'alertmanager-observability-alertmanager');
  const config = execFileSync('yq', ['-o=json', '.'], {input: Buffer.from(alertmanager.data['alertmanager.yaml'], 'base64').toString('utf8'), encoding: 'utf8'});
  return JSON.parse(config).global.smtp_from;
};
const relayOf = (stage, domains) => renderChart('postfix', [...setsOf(stage, domains),
  '--set', `postfix.config.general.ALLOWED_SENDER_DOMAINS=${domains.platformDomain} ${domains.unitApex}`]);
const statefulSetOf = (relay) => relay.find((d) => d.kind === 'StatefulSet').spec.template.spec;
const allowedDomainsOf = (relay) => relay.find((d) => d.kind === 'ConfigMap' && d.metadata.name === 'postfix').data.ALLOWED_SENDER_DOMAINS.split(/\s+/);
const keyScriptOf = (relay) => statefulSetOf(relay).initContainers.find((c) => c.name === 'fix-dkim-permissions').command.at(-1);
const keyVolumeOf = (relay) => statefulSetOf(relay).volumes.find((v) => v.name === 'dkim-keys-secret');

// What this repository decides about a receiver's verdict on one sender: the relay admits the sender's domain and has a key
// file for it. The published SPF and DKIM records are DNS, which the receiver proof reads after the release.
const senderIsSigned = (sender, allowedDomains, keyFiles) => {
  const domain = sender.slice(sender.indexOf('@') + 1);
  return allowedDomains.includes(domain) && keyFiles.includes(`${domain}.private`);
};

// Runs the init container script of a rendered relay on this machine, with its two volume paths pointed into a scratch
// folder and `chown`, which needs root, replaced by a recorder; `failing` names a command whose stand-in fails. Everything
// else is the script's own. `key` is the content of the delivered key file, or undefined when no file was delivered.
const prepareKeys = (script, key, failing = null) => {
  const scratch = mkdtempSync(join(tmpdir(), 'relay-key-'));
  try {
    const [source, keys, bin, chowned] = ['source', 'keys', 'bin', 'chowned'].map((name) => join(scratch, name));
    for (const dir of [source, keys, bin]) mkdirSync(dir);
    for (const command of ['chown', 'cp', 'chmod']) {
      if (command === failing) writeFileSync(join(bin, command), '#!/bin/sh\nexit 1\n', {mode: 0o755});
      else if (command === 'chown') writeFileSync(join(bin, command), `#!/bin/sh\necho "$@" >> '${chowned}'\n`, {mode: 0o755});
    }
    writeFileSync(chowned, '');
    if (key !== undefined) writeFileSync(join(source, 'dkim-private-key'), key);
    const run = spawnSync('sh', ['-c', script.replaceAll('/dkim-source', source).replaceAll('/dkim-keys', keys)],
      {env: {...process.env, PATH: `${bin}:${process.env.PATH}`}, encoding: 'utf8'});
    const files = readdirSync(keys).sort();
    return {status: run.status, stderr: run.stderr, files, contents: files.map((f) => readFileSync(join(keys, f), 'utf8')),
      modes: files.map((f) => statSync(join(keys, f)).mode & 0o777), chowned: readFileSync(chowned, 'utf8').split('\n').filter(Boolean)
        .map((line) => line.replaceAll(keys, '/dkim-keys'))};
  } finally {
    rmSync(scratch, {recursive: true, force: true});
  }
};
const KEY = 'a private key, in the test never a real one\n';

test('every stage sends alert mail from its unit apex, a domain the relay admits and holds a key file for', () => {
  for (const stage of STAGES) {
    const domains = domainsOf(stage);
    const sender = smtpFromOf(stage, domains);
    assert.equal(sender, `alertmanager-${stage}@${domains.unitApex}`, `the ${stage} sender`);
    const relay = relayOf(stage, domains);
    const prepared = prepareKeys(keyScriptOf(relay), KEY);
    assert.equal(prepared.status, 0, prepared.stderr);
    assert.deepEqual(prepared.files, [`${domains.platformDomain}.private`, `${domains.unitApex}.private`].sort(), `the key files of the ${stage} relay`);
    assert.ok(senderIsSigned(sender, allowedDomainsOf(relay), prepared.files), `PLANTED INNOCENT: the ${stage} alert sender is admitted and holds a key file`);
    assert.ok(senderIsSigned(`customer@${domains.platformDomain}`, allowedDomainsOf(relay), prepared.files), 'PLANTED INNOCENT: the platform domain keeps its key file');
    const older = `alertmanager-${stage}@mail.${domains.domain}`;
    assert.ok(!senderIsSigned(older, allowedDomainsOf(relay), prepared.files), 'PLANTED DEFECT: a sender on mail.<the cluster domain> has neither admission nor a key file');
    assert.ok(!senderIsSigned(sender, allowedDomainsOf(relay), [`${domains.domain}.private`]), 'PLANTED DEFECT: a key file named for the cluster domain signs nothing');
    assert.ok(!senderIsSigned(sender, [domains.platformDomain], prepared.files), 'PLANTED DEFECT: an allowlist without the unit apex refuses the alert sender');
    assert.ok(!senderIsSigned(sender, allowedDomainsOf(relay), [`${domains.platformDomain}.private`]), 'PLANTED DEFECT: an admitted domain without its key file is sent unsigned');
  }
});

test('an installation without global.unitApex gets no alert sender, and the render names the key', () => {
  assert.throws(() => smtpFromOf('prod', {...domainsOf('prod'), unitApex: ''}), /global\.unitApex-is-required/);
});

test('the relay requires its key Secret, and a key it cannot prepare ends the init container', () => {
  const relay = relayOf('prod', domainsOf('prod'));
  const volume = keyVolumeOf(relay);
  assert.equal(volume.secret.secretName, 'postfix-dkim-key');
  const isRequired = (v) => v.secret.optional !== true;
  assert.ok(isRequired(volume), 'PLANTED INNOCENT: the Secret is required, so a missing one holds the pod back instead of letting it send unsigned mail');
  assert.ok(!isRequired({secret: {...volume.secret, optional: true}}), 'PLANTED DEFECT: an optional Secret lets the relay start without its key');
  assert.deepEqual(volume.secret.items, [{key: 'dkim-private-key', path: 'dkim-private-key'}]);

  const script = keyScriptOf(relay);
  const prepared = prepareKeys(script, KEY);
  assert.equal(prepared.status, 0, prepared.stderr);
  assert.deepEqual(prepared.contents, [KEY, KEY], 'PLANTED INNOCENT: a delivered key is copied to both domain files');
  assert.deepEqual(prepared.modes, [0o600, 0o600]);
  const domains = domainsOf('prod');
  assert.deepEqual(prepared.chowned.sort(), [`101:104 /dkim-keys`, `101:104 /dkim-keys/${domains.platformDomain}.private`, `101:104 /dkim-keys/${domains.unitApex}.private`].sort(), 'the key files and the folder go to opendkim');

  for (const [name, key] of [['no key file', undefined], ['an empty key file', '']]) {
    const stopped = prepareKeys(script, key);
    assert.notEqual(stopped.status, 0, `${name} stops the init container`);
    assert.match(stopped.stderr, /dkim-private-key is missing or empty/, name);
    assert.deepEqual(stopped.files, [], `${name} leaves no key file`);
  }
  for (const command of ['cp', 'chown', 'chmod']) {
    assert.notEqual(prepareKeys(script, KEY, command).status, 0, `a failed ${command} stops the init container`);
  }
  assert.equal(prepareKeys(script.replace('set -eu\n', ''), KEY, 'chown').status, 0, 'PLANTED DEFECT: without set -e a failed chown goes unnoticed');
  assert.equal(prepareKeys(script.replace('[ -s ', '[ -f '), '').status, 0, 'PLANTED DEFECT: a test for the file instead of its content lets an empty key through');
});
