// A stand-in Manager for lifecycle/release-unit.sh, driven by lifecycle/test.sh: the admin socket's
// mint on "$RU/sock" and the API on 127.0.0.1 at the port it writes to "$RU/port". SCENARIO says how
// the release goes. Every call is logged to "$RU/calls" with whether its session cookie is the one
// issued last, a stale one or none, and never with its value: the values are sentinels, and the test
// holds every file, argument and environment of the run to carrying none of them. A release request
// is logged with its body as sent, which carries no session, so a case holds what the act asked for.
// Each sentinel carries SENTINEL_RUN, so a scan of a shared folder finds only this suite's.
import { createServer } from "node:http";
import { appendFileSync, writeFileSync } from "node:fs";

const RU = process.env.RU;
const SCENARIO = process.env.SCENARIO ?? "";
const ORIGIN = "https://manager.example.invalid";
const COOKIE = "__Host-manager";
const issued = [];
const log = (line) => appendFileSync(`${RU}/calls`, `${line}\n`);
const issue = (kind) => { issued.push(`SENTINEL-${process.env.SENTINEL_RUN}-${kind}-${issued.length + 1}`); return issued.at(-1); };

const SOURCE = { stage: "prod", tag: "0.3.004-stable-20261010101010", version: "0.3.004", channel: "stable", commit: "b".repeat(40) };
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
    const release = /^\/api\/units\/([a-z0-9-]+)\/release$/.exec(url.pathname);
    if (release && req.method === "GET") {
      if (release[1] === "ghost") return json(res, 404, { code: "NOT_FOUND", message: 'no unit "ghost" is registered, so there is nothing to release' }, refresh);
      if (SCENARIO === "mixed") return json(res, 400, { code: "VALIDATION", message: 'the release "shop" runs at prod cannot be read: its pins name 2 image tags, and one release is one image tag' }, refresh);
      return json(res, 200, { unit: release[1], version: "0.3.006", standing: SOURCE }, refresh);
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
      return json(res, 200, { id: read[1], status, summary: "a release", requiredSecrets, steps: run.steps.map((name) => ({ name, status: stepStatus })) }, refresh);
    }
    json(res, 404, { code: "NOT_FOUND", message: `no route ${req.method} ${url.pathname}` }, refresh);
  });
});
api.listen(0, "127.0.0.1", () => writeFileSync(`${RU}/port`, String(api.address().port)));
