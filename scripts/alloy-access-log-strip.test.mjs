import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import test from 'node:test';

// A token in a URL must not reach Loki, so Alloy cuts the query off the two fields of Traefik's access
// log that can carry one, RequestPath and request_Referer, before it ships the line. The stage is read
// out of the config each chart renders and applied with RE2, the engine Alloy's replace stage uses,
// by scripts/alloy-replace: the stage replaces what its capture groups matched, so the group is the
// part that is cut. The stage itself was run on Alloy v1.18.0, the release the chart pins, when it was
// written; this test keeps the rendered stage to what that run showed.
const yaml = (expression, input) => JSON.parse(execFileSync('yq', ['-o=json', expression, '-'], {input, encoding: 'utf8'}));
const render = (...args) => yaml('select(.kind == "ConfigMap" and .metadata.name == "alloy-config") | .data."config.alloy"',
  execFileSync('helm', ['template', 'monitoring', 'clusters/charts/monitoring', '--namespace', 'observability',
    '-f', 'clusters/platform/values-common.yaml', '-f', 'scripts/standin/cluster-map.yaml', ...args], {encoding: 'utf8'}));
const CONFIGS = {
  'the agent of an app cluster': render('--set', 'alloyAgent.enabled=true'),
  'the shipper of the logs (alloy.logsEnabled)': render('--set', 'alloy.logsEnabled=true'),
};

// The two renders are different configs: only a slave's agent pushes metrics, and a test that read one
// config twice would answer for the other without having looked at it.
test('the two renders are the two configs', () => {
  const [agent, shipper] = Object.values(CONFIGS);
  assert.ok(agent.includes('prometheus.remote_write'));
  assert.ok(!shipper.includes('prometheus.remote_write'));
});

const apply = (stage, lines) => JSON.parse(execFileSync('go', ['run', 'scripts/alloy-replace/main.go'],
  {input: JSON.stringify({...stage, lines}), encoding: 'utf8'}));

// The stage as the config writes it: the labels it selects on and the expression it replaces with.
function stageOf(config) {
  const [, selector, expression, replace] = config.match(
    /stage\.match \{\s*selector\s*=\s*`([^`]*)`\s*stage\.replace \{\s*expression\s*=\s*`([^`]*)`\s*replace\s*=\s*"([^"]*)"/) ?? [];
  assert.ok(expression !== undefined, 'the config has no stage.match around a stage.replace');
  return {selector, expression, replace};
}
// A selector of equality matchers, which is all this config writes.
const selects = (selector, labels) => [...selector.matchAll(/(\w+)="([^"]*)"/g)].every(([, name, value]) => labels[name] === value);

const SECRET = 'SECRETTOKEN';
const line = fields => JSON.stringify({ClientAddr: '10.0.0.9:41090', DownstreamStatus: 200, RequestHost: 'shop.example.test', ...fields, level: 'info', msg: '', time: '2026-10-19T09:00:00Z'});
const TRAEFIK = {namespace: 'ingress', container: 'traefik'};
// [name, labels, line, line expected after the stage]
const CASES = [
  ['a query on the path', TRAEFIK, line({RequestPath: `/reset?token=${SECRET}`}), line({RequestPath: '/reset'})],
  ['an ampersand, which Traefik writes as \\u0026', TRAEFIK, line({RequestPath: `/a?x=1&token=${SECRET}`}).replace('&', '\\u0026'), line({RequestPath: '/a'})],
  ['an escaped quote inside the query', TRAEFIK, line({RequestPath: `/a?x="y"&token=${SECRET}`}), line({RequestPath: '/a'})],
  ['a query on the referrer', TRAEFIK, line({RequestPath: '/', 'request_Referer': `https://shop.example.test/verify?code=${SECRET}`}),
    line({RequestPath: '/', 'request_Referer': 'https://shop.example.test/verify'})],
  ['an empty query', TRAEFIK, line({RequestPath: '/a?'}), line({RequestPath: '/a'})],
  // The planted innocents: nothing to cut, a field that is not a URL, and another container's line.
  ['a path without a query', TRAEFIK, line({RequestPath: '/plain'}), line({RequestPath: '/plain'})],
  ['a header that quotes the field', TRAEFIK, line({RequestPath: '/plain', 'request_User-Agent': '"RequestPath":"/x?y=1"'}),
    line({RequestPath: '/plain', 'request_User-Agent': '"RequestPath":"/x?y=1"'})],
  ['a line of another container', {namespace: 'shop', container: 'web'}, JSON.stringify({RequestPath: '/kept?x=1', level: 30}), JSON.stringify({RequestPath: '/kept?x=1', level: 30})],
];

// Whatever the stage leaves of every case that differs from what it must leave, named.
function findings(config) {
  const stage = stageOf(config);
  const selected = CASES.map(([, labels]) => selects(stage.selector, labels));
  const through = apply(stage, CASES.map(([, , input]) => input));
  return CASES.flatMap(([name, , input, expected], at) => {
    const left = selected[at] ? through[at] : input;
    return left === expected ? [] : [`${name}: ${left}`];
  });
}

for (const [name, config] of Object.entries(CONFIGS)) {
  test(`${name} cuts the query off the request path and the referrer, and nothing else`, () => {
    assert.deepEqual(findings(config), []);
  });
}

test('PLANTED DEFECT: a stage that cuts nothing, too little, too much or on every container is caught', () => {
  const config = CONFIGS['the agent of an app cluster'];
  const stage = stageOf(config);
  const change = (from, to) => { assert.ok(config.includes(from), from); return config.replace(from, to); };
  for (const [name, planted] of [
    ['no group, so nothing is cut', change(stage.expression, '"RequestPath":"[^"?]*\\?[^"]*"')],
    ['a query that ends at the first escaped quote', change(stage.expression, '"(?:RequestPath|request_Referer)":"[^"?]*(\\?[^"]*)"')],
    ['the referrer left alone', change(stage.expression, stage.expression.replace('|request_Referer', ''))],
    ['the whole path cut with its query', change(stage.expression, '"(?:RequestPath|request_Referer)":"((?:[^"?\\\\]|\\\\.)*\\?(?:[^"\\\\]|\\\\.)*)"')],
    ['every container selected', change(stage.selector, '{namespace=~".+"}')],
  ]) assert.notDeepEqual(findings(planted), [], name);
});
