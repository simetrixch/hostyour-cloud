// A stand-in Manager for lifecycle/release-unit.sh, driven by lifecycle/test.sh: the admin socket's
// mint on "$RU/sock" and the API on 127.0.0.1 at the port it writes to "$RU/port". SCENARIO says how
// the release goes. Every call is logged to "$RU/calls" with whether its session cookie is the one
// issued last, a stale one or none, and never with its value: the values are sentinels, and the test
// holds every file, argument and environment of the run to carrying none of them. A release request
// is logged with its body as sent, which carries no session, so a case holds what the act asked for.
// Each sentinel carries SENTINEL_RUN, so a scan of a shared folder finds only this suite's.
//
// THE TENANTS. After a run succeeds the act reads the tenants that follow releases. A scenario named
// follow-* plays one world of tenants: each GET /api/runs is one look of the act and moves the world to
// its next round (the last round repeats), and the versions, runs and live reads answer from the round
// they stand in. Every other scenario has no tenant at all. The decoy tenants are suspended, not
// following, on another stage, not active, or render no part of the unit, and run an old version: a
// call that names one is a defect of the act, and the call list shows it. A world with a stageTag
// answers the release read of the stage test with that tag, as another release would have left it.
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
const NEW = `${SOURCE.tag}-abc1234`;
/** The tag another release of the unit put on the stage between this run and the act's read of it. */
const RACED = "0.3.005-stable-20261011101010";
const tenant = (id, over = {}) => ({ id, guid: `guid-${id}`, subdomain: id, stage: "test", status: "active", suspended: false, followReleases: true, members: ["auth"], ...over });
const versionsRun = (id, tenantId, status, when) => ({ id, kind: "tenant-refresh-members", targetKind: "tenant", targetId: tenantId, status, creation: START + when });
const part = (running, name = "shop") => ({ name, builds: [name], running, versions: [] });
const DECOYS = [
  tenant("tnt_suspended", { suspended: true }), tenant("tnt_unfollowing", { followReleases: false }),
  tenant("tnt_prod", { stage: "prod" }), tenant("tnt_provisioning", { status: "provisioning" }), tenant("tnt_other"),
];
const SYNCED = { argo: { ok: true, sync: "Synced", health: "Healthy", syncRevision: "r" } };
const lineMoveRun = (status, when) => ({ ...versionsRun("run_l1", "tnt_1", status, when), kind: "tenant-line-move" });
/** The worlds: the tenants, then per round the runs the Manager lists, each tenant's parts and live state. */
const WORLDS = {
  "follow-moves": { tenants: [tenant("tnt_1"), ...DECOYS], rounds: [
    { runs: [versionsRun("run_v1", "tnt_1", "running", AFTER + 500), lineMoveRun("failed", AFTER + 900)], parts: { tnt_1: [part([OLD])] } },
    { runs: [versionsRun("run_v1", "tnt_1", "succeeded", AFTER + 500), lineMoveRun("failed", AFTER + 900)], parts: { tnt_1: [part([NEW])] } },
  ] },
  "follow-relay-lost": { tenants: [tenant("tnt_1")], rounds: [
    { runs: [versionsRun("run_v1", "tnt_1", "running", AFTER)], parts: { tnt_1: [part([OLD])] } },
    { runs: [versionsRun("run_v1", "tnt_1", "succeeded", AFTER)], parts: { tnt_1: [part([NEW])] } },
  ] },
  "follow-unrelated": { tenants: [tenant("tnt_other")], rounds: [{ runs: [], parts: {} }] },
  "follow-never": { tenants: [tenant("tnt_1")], rounds: [{ runs: [], parts: { tnt_1: [part([OLD])] } }] },
  "follow-failed": { tenants: [tenant("tnt_1"), tenant("tnt_2")], rounds: [
    { runs: [versionsRun("run_v1", "tnt_1", "failed", AFTER), versionsRun("run_v2", "tnt_2", "succeeded", AFTER)], parts: { tnt_1: [part([OLD])], tnt_2: [part([NEW])] } },
  ] },
  "follow-superseded": { tenants: [tenant("tnt_1")], rounds: [
    { runs: [versionsRun("run_v2", "tnt_1", "succeeded", AFTER + 2000), versionsRun("run_v1", "tnt_1", "failed", AFTER + 1000)], parts: { tnt_1: [part([NEW])] } },
  ] },
  "follow-line": { tenants: [tenant("tnt_1")], rounds: [{ runs: [], parts: { tnt_1: [part(["0.2.007-stable-20260901101010-2222222"])] } }] },
  "follow-held": { tenants: [tenant("tnt_1")], rounds: [{ runs: [versionsRun("run_v1", "tnt_1", "failed", BEFORE)], parts: { tnt_1: [part([NEW])] } }] },
  "follow-held-superseded": { tenants: [tenant("tnt_1")], live: SYNCED, rounds: [
    { runs: [versionsRun("run_v2", "tnt_1", "succeeded", BEFORE + 500), versionsRun("run_v1", "tnt_1", "failed", BEFORE)], parts: { tnt_1: [part([NEW])] } },
  ] },
  "follow-raced": { tenants: [tenant("tnt_1")], stageTag: RACED, rounds: [
    { runs: [versionsRun("run_v1", "tnt_1", "succeeded", AFTER)], parts: { tnt_1: [part([`${RACED}-abc1234`])] } },
  ] },
  "follow-recorded": { tenants: [tenant("tnt_1")], rounds: [{ runs: [], parts: { tnt_1: [part([NEW])] } }] },
  "follow-unsynced": { tenants: [tenant("tnt_1")], live: { argo: { ok: true, sync: "OutOfSync", health: "Healthy", syncRevision: "r" } }, rounds: [
    { runs: [versionsRun("run_v1", "tnt_1", "succeeded", BEFORE)], parts: { tnt_1: [part([NEW])] } },
  ] },
};
const world = WORLDS[SCENARIO];
let looks = 0;
const round = () => world.rounds[Math.min(Math.max(looks, 1), world.rounds.length) - 1];
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
      looks += 1;
      return json(res, 200, round().runs, refresh);
    }
    const versions = /^\/api\/tenants\/([a-z0-9_]+)\/versions$/.exec(url.pathname);
    if (versions && req.method === "GET") {
      const parts = round().parts[versions[1]] ?? [versions[1] === "tnt_other" ? part([OLD], "other") : part([OLD])];
      return json(res, 200, { stage: "test", members: ["auth"], parts }, refresh);
    }
    const live = /^\/api\/tenants\/([a-z0-9_]+)\/live$/.exec(url.pathname);
    if (live && req.method === "GET") return json(res, 200, { row: { id: live[1] }, ...(world?.live ?? SYNCED) }, refresh);
    const release = /^\/api\/units\/([a-z0-9-]+)\/release$/.exec(url.pathname);
    if (release && req.method === "GET") {
      if (release[1] === "ghost") return json(res, 404, { code: "NOT_FOUND", message: 'no unit "ghost" is registered, so there is nothing to release' }, refresh);
      if (SCENARIO === "mixed") return json(res, 400, { code: "VALIDATION", message: 'the release "shop" runs at prod cannot be read: its pins name 2 image tags, and one release is one image tag' }, refresh);
      const standing = url.searchParams.get("stage") === "test" && world?.stageTag ? { ...SOURCE, tag: world.stageTag } : SOURCE;
      return json(res, 200, { unit: release[1], version: "0.3.006", standing }, refresh);
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
