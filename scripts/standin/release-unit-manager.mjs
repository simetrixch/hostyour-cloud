// A stand-in Manager for lifecycle/release-unit.sh, driven by lifecycle/test.sh: the admin socket's
// mint on "$RU/sock" and the API on 127.0.0.1 at the port it writes to "$RU/port". SCENARIO says how
// the release goes. Every call is logged to "$RU/calls" with whether its session cookie is the one
// issued last, a stale one or none, and never with its value: the values are sentinels, and the test
// holds every file, argument and environment of the run to carrying none of them. A release request
// is logged with its body as sent, which carries no session, so a case holds what the act asked for.
// Each sentinel carries SENTINEL_RUN, so a scan of a shared folder finds only this suite's.
//
// THE TENANTS. After a run succeeds the act reads the tenants that follow releases. A scenario named
// follow-* plays one world of tenants: each GET /api/tenants/<id>/versions is one look of the act at
// that tenant and moves the tenant to its next round (the last round repeats), and the versions and
// live reads of the tenant answer from the round it stands in. A part carries `runs`, the Versions runs
// that moved it to an image tag as the Manager projects them (the newest per tag), and a live answer
// carries `versions`, the tags the Application's last comparison rendered. The global list of runs,
// GET /api/runs, answers the newest hundred of `globalRuns` and moves nothing: it holds the runs the act
// must not judge a tenant by, a discarded run of nothing to change among them, and a call that reads it
// is a defect of the act, which the call list shows. Every other scenario has no tenant at all. The
// decoy tenants are suspended, not following, on another stage, not active, or render no part of the
// unit, and run an old version: a call that names one is a defect of the act, and the call list shows
// it. A world with a stageTag answers the release read of the stage test with that tag, as another
// release would have left it, and one with carriers adds them to that answer, as the Manager does for a
// build-only unit.
import { createServer } from "node:http";
import { appendFileSync, writeFileSync } from "node:fs";

const RU = process.env.RU;
const SCENARIO = process.env.SCENARIO ?? "";
const ORIGIN = "https://manager.example.invalid";
const COOKIE = "__Host-manager";
const issued = [];
const log = (line) => appendFileSync(`${RU}/calls`, `${line}\n`);
const issue = (kind) => { issued.push(`SENTINEL-${process.env.SENTINEL_RUN}-${kind}-${issued.length + 1}`); return issued.at(-1); };

/** When the release run started, in ms; a Versions run is created AFTER it or BEFORE it. */
const START = 1_760_000_000_000;
const AFTER = 1000;
const BEFORE = -1000;
const SOURCE = { stage: "prod", tag: "0.3.004-stable-20261010101010", version: "0.3.004", channel: "stable", commit: "b".repeat(40) };
const OLD = "0.3.003-stable-20261001101010-1111111";
/** The image tag of the release: its tag and the first seven digits of its commit. */
const NEW = `${SOURCE.tag}-bbbbbbb`;
/** The image tag of another release of the unit. */
const OTHER = "0.3.006-stable-20261012101010-ccccccc";
/** The tag another release of the unit put on the stage between this run and the act's read of it. */
const RACED = "0.3.005-stable-20261011101010";
const tenant = (id, over = {}) => ({ id, guid: `guid-${id}`, subdomain: id, stage: "test", status: "active", suspended: false, followReleases: true, members: ["auth"], ...over });
const ended = (status) => ["succeeded", "failed", "cancelled"].includes(status);
/** A Versions run that moved the part to the image tag `tag`, as the Manager projects it into the part. */
const move = (id, status, when, tag = NEW) => ({ id, tag, status, creation: START + when, startedAt: START + when + 10, endedAt: ended(status) ? START + when + 20 : null });
/** A Versions run of a tenant as the global list of runs holds it, whether or not it moved the part. */
const globalRun = (id, tenantId, status, when) => ({ id, kind: "tenant-refresh-members", targetKind: "tenant", targetId: tenantId, status, creation: START + when });
const part = (running, { name = "shop", builds = [name], runs = [] } = {}) => ({ name, builds, running, versions: [], runs });
/** The live answer of a tenant: its Application, and the tags its last comparison rendered. */
const synced = { ok: true, sync: "Synced", health: "Healthy", syncRevision: "r" };
const live = (versions, argo = synced) => ({ argo, versions });
/** A round of one tenant: the parts it answers, and its live answer. */
const round = (parts, liveAnswer = live(null)) => ({ parts, live: liveAnswer });
/** The runs the global list holds besides the tenant's own: another tenant's, another kind's, and the newest hundred of noise. */
const noise = (count) => Array.from({ length: count }, (_, i) => ({ id: `run_n${i}`, kind: "unit-release", targetKind: "cluster", targetId: "cls_1", status: "succeeded", creation: START + AFTER + 10_000 + i }));
const DECOYS = [
  tenant("tnt_suspended", { suspended: true }), tenant("tnt_unfollowing", { followReleases: false }),
  tenant("tnt_prod", { stage: "prod" }), tenant("tnt_provisioning", { status: "provisioning" }), tenant("tnt_other"),
];
/** A world with one following tenant, tnt_1, whose rounds are given. */
const single = (rounds, over = {}) => ({ tenants: [tenant("tnt_1")], rounds: { tnt_1: rounds }, ...over });
const RENDERED = live({ shop: NEW });
/** The worlds: the tenants, per tenant the rounds its reads walk through, the global runs and the stage's tag. */
const WORLDS = {
  "follow-moves": { tenants: [tenant("tnt_1"), ...DECOYS], globalRuns: [globalRun("run_d1", "tnt_1", "cancelled", AFTER + 300), { ...globalRun("run_l1", "tnt_1", "failed", AFTER + 900), kind: "tenant-line-move" }], rounds: { tnt_1: [
    round([part([OLD])]),
    round([part([OLD], { runs: [move("run_v1", "running", AFTER + 500)] })]),
    round([part([NEW], { runs: [move("run_v1", "succeeded", AFTER + 500)] })]),
  ] } },
  "follow-relay-lost": single([
    round([part([OLD], { runs: [move("run_v1", "running", AFTER)] })]),
    round([part([NEW], { runs: [move("run_v1", "succeeded", AFTER)] })]),
  ]),
  "follow-unrelated": { tenants: [tenant("tnt_other")], rounds: {} },
  "follow-never": single([round([part([OLD])])]),
  "follow-failed": { tenants: [tenant("tnt_1"), tenant("tnt_2")], rounds: {
    tnt_1: [round([part([OLD], { runs: [move("run_v1", "failed", AFTER)] })])],
    tnt_2: [round([part([NEW], { runs: [move("run_v2", "succeeded", AFTER)] })])],
  } },
  "follow-cancelled": single([round([part([OLD], { runs: [move("run_v1", "cancelled", AFTER)] })])]),
  "follow-discarded": single([
    round([part([OLD])]),
    round([part([OLD], { runs: [move("run_v1", "running", AFTER + 500)] })]),
    round([part([NEW], { runs: [move("run_v1", "succeeded", AFTER + 500)] })]),
  ], { globalRuns: [globalRun("run_d1", "tnt_1", "cancelled", AFTER + 300)] }),
  "follow-other-tag": single([
    round([part([OLD], { runs: [move("run_x1", "failed", AFTER + 100, OTHER)] })]),
    round([part([OLD], { runs: [move("run_x1", "failed", AFTER + 100, OTHER), move("run_v1", "running", AFTER + 500)] })]),
    round([part([NEW], { runs: [move("run_x1", "failed", AFTER + 100, OTHER), move("run_v1", "succeeded", AFTER + 500)] })]),
  ]),
  "follow-many-runs": single([round([part([NEW], { runs: [move("run_v1", "succeeded", AFTER + 500)] })])], { globalRuns: [globalRun("run_v1", "tnt_1", "succeeded", AFTER + 500), ...noise(105)] }),
  "follow-no-runs": single([round([{ name: "shop", builds: ["shop"], running: [OLD], versions: [] }])]),
  "follow-no-versions": single([round([part([NEW], { runs: [move("run_v1", "succeeded", AFTER)] })], { argo: { ok: true, sync: "Synced", health: "Healthy", syncRevision: "r" } })]),
  "follow-no-commit": single([round([part([OLD])])], { noCommit: true }),
  "follow-line": single([round([part(["0.2.007-stable-20260901101010-2222222"])])]),
  "follow-rendered-cancelled": single([round([part([NEW], { runs: [move("run_v1", "cancelled", AFTER)] })], RENDERED)]),
  "follow-rendered-failed": single([round([part([NEW], { runs: [move("run_v1", "failed", AFTER)] })], RENDERED)]),
  "follow-rendered": single([round([part([NEW])], RENDERED)]),
  "follow-builds": { tenants: [tenant("tnt_1"), tenant("tnt_2")], rounds: {
    tnt_1: [round([part([NEW, NEW], { builds: ["shop", "shop-worker"] })], live({ shop: NEW, "shop-worker": NEW }))],
    tnt_2: [round([part([NEW, NEW], { builds: ["shop", "shop-worker"] })], live({ shop: NEW }))],
  } },
  "follow-bundle": { tenants: [tenant("tnt_1"), tenant("tnt_2")], rounds: {
    tnt_1: [round([part([NEW], { builds: ["shop-apps"] })], live({ "shop-apps": NEW }))],
    tnt_2: [round([part([NEW], { builds: ["shop-apps"] })], live({ "shop-apps": OLD }))],
  } },
  "follow-recorded": single([round([part([NEW])])]),
  "follow-old-render": single([round([part([NEW], { runs: [move("run_v1", "succeeded", BEFORE)] })], live({ shop: OLD }))]),
  "follow-unsynced": single([round([part([NEW], { runs: [move("run_v1", "succeeded", BEFORE)] })], live(null, { ok: true, sync: "OutOfSync", health: "Healthy", syncRevision: "r" }))]),
  "follow-unreadable": single([round([part([NEW], { runs: [move("run_v1", "succeeded", BEFORE)] })], live(null, { ok: false, error: "the Application could not be read" }))]),
  "follow-held": single([round([part([NEW], { runs: [move("run_v1", "failed", BEFORE)] })])]),
  "follow-held-rendered-failed": single([round([part([NEW], { runs: [move("run_v1", "failed", BEFORE)] })], RENDERED)]),
  "follow-held-rendered-cancelled": single([round([part([NEW], { runs: [move("run_v1", "cancelled", BEFORE)] })], RENDERED)]),
  "follow-held-succeeded": single([round([part([NEW], { runs: [move("run_v1", "succeeded", BEFORE)] })], RENDERED)]),
  "follow-raced": single([round([part([`${RACED}-bbbbbbb`], { runs: [move("run_v1", "succeeded", AFTER, `${RACED}-bbbbbbb`)] })])], { stageTag: RACED }),
  "follow-promotion": { tenants: [tenant("tnt_prod", { stage: "prod" }), tenant("tnt_1")], carriers: true, rounds: {
    tnt_prod: [
      round([part([OLD])]),
      round([part([NEW], { runs: [move("run_p1", "succeeded", AFTER + 500)] })]),
    ],
    tnt_1: [
      round([part([OLD])]),
      round([part([OLD], { runs: [move("run_v1", "running", AFTER + 500)] })]),
      round([part([NEW], { runs: [move("run_v1", "succeeded", AFTER + 500)] })]),
    ],
  } },
};
const world = WORLDS[SCENARIO];
/** How often the act has read each tenant's versions: the round it stands in. */
const looks = new Map();
const standingOf = (tenantId) => {
  const rounds = world?.rounds[tenantId] ?? [round([part([OLD], { name: tenantId === "tnt_other" ? "other" : "shop" })])];
  return rounds[Math.min(Math.max(looks.get(tenantId) ?? 0, 1), rounds.length) - 1];
};
/** The runs, each a script of the statuses its reads walk through. */
const runs = new Map();
const after = { failed: ["running", "failed"], cancelled: ["running", "cancelled"] }[SCENARIO] ?? ["running", "running", "succeeded"];
const json = (res, status, body, headers = {}) => { res.writeHead(status, { "content-type": "application/json", ...headers }); res.end(JSON.stringify(body)); };

createServer((req, res) => {
  log("MINT");
  json(res, 200, { session: issue("session") });
}).listen(`${RU}/sock`);

const api = createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => { body += chunk; });
  req.on("end", () => {
    const presented = /(?:^|; )__Host-manager=([^;]*)/.exec(req.headers.cookie ?? "")?.[1];
    const which = presented === undefined ? "none" : presented === issued.at(-1) ? "current" : issued.includes(presented) ? "stale" : "unknown";
    const origin = req.method === "GET" ? "n/a" : req.headers.origin === ORIGIN ? "ok" : "missing";
    log(`${req.method} ${req.url} cookie=${which} origin=${origin}`);
    if (which === "none" || which === "unknown") return json(res, 401, { code: "UNAUTHENTICATED", message: "Not signed in" });
    if (origin === "missing") return json(res, 403, { code: "CSRF_REFUSED", message: "cross-origin request refused" });
    const refresh = { "set-cookie": `${COOKIE}=${issue("refresh")}; Path=/; HttpOnly; Secure; SameSite=Lax` };
    const url = new URL(req.url, "http://manager");
    if (req.method === "GET" && url.pathname === "/api/tenants") {
      if (SCENARIO === "follow-relay-lost") writeFileSync(`${RU}/relay-fails`, "3");
      return json(res, 200, world?.tenants ?? [], refresh);
    }
    if (req.method === "GET" && url.pathname === "/api/runs") {
      const newest = [...(world?.globalRuns ?? [])].sort((a, b) => b.creation - a.creation).slice(0, 100);
      return json(res, 200, newest, refresh);
    }
    const versions = /^\/api\/tenants\/([a-z0-9_]+)\/versions$/.exec(url.pathname);
    if (versions && req.method === "GET") {
      looks.set(versions[1], (looks.get(versions[1]) ?? 0) + 1);
      return json(res, 200, { stage: "test", members: ["auth"], parts: standingOf(versions[1]).parts }, refresh);
    }
    const liveRead = /^\/api\/tenants\/([a-z0-9_]+)\/live$/.exec(url.pathname);
    if (liveRead && req.method === "GET") return json(res, 200, { row: { id: liveRead[1] }, ...standingOf(liveRead[1]).live }, refresh);
    const release = /^\/api\/units\/([a-z0-9-]+)\/release$/.exec(url.pathname);
    if (release && req.method === "GET") {
      if (release[1] === "ghost") return json(res, 404, { code: "NOT_FOUND", message: 'no unit "ghost" is registered, so there is nothing to release' }, refresh);
      if (SCENARIO === "mixed") return json(res, 400, { code: "VALIDATION", message: 'the release "shop" runs at prod cannot be read: its pins name 2 image tags, and one release is one image tag' }, refresh);
      const stage = url.searchParams.get("stage");
      const lagging = { carrier: "tenant tnt_prod", pin: { name: "shop", image: "shop", tag: OLD } };
      const carriers = { pins: stage === "prod" ? [{ carrier: "deploy chart", pin: { name: "shop", image: "shop", tag: NEW } }] : [], tenants: stage === "prod" ? [lagging] : [] };
      const { commit, ...unnamed } = { ...SOURCE, ...(stage === "test" && world?.stageTag ? { tag: world.stageTag } : {}), ...(world?.carriers ? { carriers } : {}) };
      return json(res, 200, { unit: release[1], version: "0.3.006", standing: world?.noCommit ? unnamed : { ...unnamed, commit } }, refresh);
    }
    if (release && req.method === "POST") {
      log(`  body ${body}`);
      const asked = JSON.parse(body);
      const runId = `run_${runs.size + 1}`;
      // The three refusals the Manager's plan makes, each settling the run failed at its plan.
      const refused = release[1] === "ghost" || asked.commit === "d".repeat(40) || asked.version === "0.2.000";
      const steps = asked.sourceTag !== undefined && SCENARIO !== "wrong-steps" ? ["put-release"] : ["mint-release", "watch-release-build"];
      runs.set(runId, { statuses: ["planning", refused ? "failed" : "planned"], steps, approved: false });
      if (SCENARIO === "lost-post") return req.socket.destroy();
      return json(res, 201, { runId }, refresh);
    }
    const approve = /^\/api\/runs\/([a-z0-9_]+)\/approve$/.exec(url.pathname);
    if (approve) {
      const run = runs.get(approve[1]);
      if (SCENARIO === "dropped-approve") return req.socket.destroy();
      run.statuses = ["queued", ...after];
      run.approved = true;
      if (SCENARIO === "relay-lost") writeFileSync(`${RU}/relay-fails`, "3");
      if (SCENARIO === "watch-exhausted") writeFileSync(`${RU}/relay-fails`, "99");
      if (SCENARIO === "relay-hangs") writeFileSync(`${RU}/relay-hangs`, "2");
      if (SCENARIO === "lost-approve") return req.socket.destroy();
      return json(res, 200, { status: "queued" }, refresh);
    }
    const read = /^\/api\/runs\/([a-z0-9_]+)$/.exec(url.pathname);
    if (read && runs.has(read[1])) {
      const run = runs.get(read[1]);
      if (SCENARIO === "expired" && run.statuses[0] === "running") return json(res, 401, { code: "UNAUTHENTICATED", message: "Not signed in" });
      const status = run.statuses.length > 1 ? run.statuses.shift() : run.statuses[0];
      const stepStatus = status === "succeeded" ? "ok" : status === "running" ? "running" : status === "failed" && run.approved ? "failed" : "pending";
      const requiredSecrets = SCENARIO === "secrets" ? [{ name: "elevation-password" }] : [];
      const startedAt = ["planning", "planned", "queued"].includes(status) ? null : START;
      return json(res, 200, { id: read[1], status, summary: "a release", startedAt, requiredSecrets, steps: run.steps.map((name) => ({ name, status: stepStatus })) }, refresh);
    }
    json(res, 404, { code: "NOT_FOUND", message: `no route ${req.method} ${url.pathname}` }, refresh);
  });
});
api.listen(0, "127.0.0.1", () => writeFileSync(`${RU}/port`, String(api.address().port)));
