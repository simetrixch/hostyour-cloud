// release-unit: ONE release of ONE unit, planned, approved and watched over the Manager's admin access,
// from the operator's machine. The run, its gates and its record are the ones the Release dialog
// makes: the same POST /api/units/<unit>/release, the same approve, the same run page.
//
// HOW IT REACHES THE MANAGER. Every exchange is one `ssh <door> microk8s.kubectl exec -i` into the
// Manager's container, where the node the container ships runs `relay` below: it reads one request
// on its standard input, makes it to the admin socket (the mint) or to the Manager's own port, and
// writes one answer line to its standard output. Both pipes belong to this process, and the relay
// keeps nothing. So a rollout that replaces the Manager's pod ends at most one exchange, and the next
// one reaches the new pod with the same session.
//
// THE SESSION. It is minted ONCE, over the admin socket, and lives in this process's memory only:
// never in an argument, an environment variable, a file or a line printed. It rides each request as
// the session cookie, under the name PUBLIC_URL selects (the Manager's own rule, server/kernel/
// config.ts cookieSecure and server/domains/access/session.ts sessionCookieName), because only the
// cookie carrier is refreshed (server/http/middleware/chokepoint.ts); the refreshed cookie replaces
// it. A mutation carries PUBLIC_URL's origin, which the Manager's CSRF guard holds it to. An expired
// or revoked session ends the watch: nothing is minted again.
//
// NOTHING IS SENT TWICE. A plan or an approve whose answer is lost is not repeated: what it did is
// read, never guessed. Reads are repeated across a lost relay, up to RELEASE_UNIT_RETRIES times in a
// row. The run id is printed as soon as it is known and named in every later line.
//
// THE TENANTS THAT FOLLOW. A succeeded release run proves only that the stage pin stands: the tenants
// that follow releases move afterwards, each in its own Versions run (tenant-refresh-members), and that
// run may fail. So after `run succeeded` the script waits for every active tenant at the stage that
// follows releases and renders the unit, and exits 0 only when each runs the stage's release. The
// release is the one the stage pins after the run, and it must be the release this run put there: with
// --prod-to-test prod's tag, else the version and channel of the arguments. Its image tag is that tag
// and the first seven digits of its commit.
//
// A TENANT IS JUDGED BY ITS OWN READS, never by the list of all runs. The part's `runs` in
// GET /api/tenants/<id>/versions name the Versions run that moved the part to an image tag. A tenant has
// landed when every version of its part is the image tag and the run that moved the part to it succeeded
// after this release run started (the Manager ends that run only when ArgoCD rendered the versions): the
// record of the running versions turns at the pin write, and one look at an Application that may still
// show the revision from before it proves nothing. A run that moved the part to the image tag and failed
// or was cancelled ends the script, when it ran after this release started or the tenant records the tag.
// A run that moved nothing to the image tag, one discarded because its plan changed nothing among them,
// is not a run of this release and is never read. Where the Manager names no `runs` for the part the
// script stops, and it never falls back to the newest run. A tenant on another version line than the
// release is left to Move to line and not waited for. With --prod-to-test the same rule is read before
// the release request, where nothing is in flight: a tenant that records the tag while the run that
// moved it failed ends the script there, because planning the release again would change nothing for
// it, and one that records the tag and whose live Application is Synced and Healthy already runs it and
// is not waited for.
import { spawn } from "node:child_process";

const USAGE = [
  "usage: lifecycle/release-unit.sh <user@master-host> <unit> --prod-to-test",
  "       lifecycle/release-unit.sh <user@master-host> <unit> <dev|test|prod|none> <alpha|beta|stable> <x.y.z> <commit>",
].join("\n");
/** Exit codes: a run or a Versions run that did not succeed, a usage error, a Manager that could not be
 *  reached, a watch that stopped or a wait for the following tenants that ran out. */
const EXIT = { failed: 1, usage: 64, unavailable: 69, watchStopped: 75 };
const TERMINAL = new Set(["succeeded", "failed", "cancelled"]);

/** A whole number of an operator's setting, or its default. */
function setting(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  if (!/^[0-9]+$/.test(raw)) stop(`${name} must be a whole number (got '${raw}')`, EXIT.usage);
  return Number(raw);
}

/** The relay, run by the Manager container's node. It reads PUBLIC_URL, ADMIN_SOCKET_PATH and PORT
 *  from the container's environment and prints none of them. Every failure is one answer line, so
 *  node never prints a stack that could quote the request. */
function relay() {
  const http = require("node:http");
  const answer = (value) => { process.stdout.write(`${JSON.stringify(value)}\n`); };
  process.on("uncaughtException", () => { answer({ error: "relay" }); process.exit(1); });
  let input = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => { input += chunk; });
  process.stdin.on("end", () => {
    const request = JSON.parse(input);
    const pub = new URL(process.env.PUBLIC_URL);
    const cookie = pub.protocol === "https:" ? "__Host-manager" : "manager-session";
    const headers = { accept: "application/json" };
    if (request.kind === "http") {
      headers.cookie = `${cookie}=${request.session}`;
      if (request.method !== "GET") headers.origin = pub.origin;
      if (request.body !== undefined) headers["content-type"] = "application/json";
    }
    const target = request.kind === "mint"
      ? { socketPath: process.env.ADMIN_SOCKET_PATH, method: "POST", path: "/auth/session" }
      : { host: "127.0.0.1", port: Number(process.env.PORT || 8484), method: request.method, path: request.path };
    const sent = http.request({ ...target, headers }, (res) => {
      let body = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { body += chunk; });
      res.on("end", () => {
        const refreshed = [].concat(res.headers["set-cookie"] || []).map((c) => c.split(";")[0]).find((c) => c.startsWith(`${cookie}=`));
        answer({ status: res.statusCode, body, ...(refreshed ? { session: refreshed.slice(cookie.length + 1) } : {}) });
      });
    });
    sent.on("error", (e) => { answer({ error: e.code || "transport" }); process.exitCode = 1; });
    if (request.body !== undefined) sent.write(JSON.stringify(request.body));
    sent.end();
  });
}
const REMOTE = `microk8s.kubectl exec -i -n manager deploy/manager -c manager -- node -e 'eval(Buffer.from("${Buffer.from(`(${relay.toString()})()`).toString("base64")}","base64").toString())'`;

/** Every session value this process has held, so no line it prints can carry one. */
const held = new Set();
let session = null;
const redact = (text) => [...held].reduce((t, s) => t.split(s).join("<session>"), String(text));
const say = (line) => { process.stdout.write(`${redact(line)}\n`); };
function stop(line, code) {
  process.stderr.write(`release-unit: ${redact(line)}\n`);
  process.exit(code);
}
const sleep = (ms) => new Promise((resolve) => { setTimeout(resolve, ms); });

/** One exchange through a new relay: its answer, or null where the relay gave none in EXCHANGE_MS. */
function exchange(request) {
  return new Promise((resolve) => {
    const child = spawn("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", DOOR, REMOTE], { stdio: ["pipe", "pipe", "pipe"] });
    const bound = setTimeout(() => child.kill("SIGKILL"), EXCHANGE_MS);
    let out = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { out += chunk; });
    child.stderr.resume(); // what ssh and kubectl say stays here: only an allowlisted line is printed
    child.on("error", () => { clearTimeout(bound); resolve(null); });
    child.on("close", () => {
      clearTimeout(bound);
      try {
        const answer = JSON.parse(out.trim().split("\n").pop());
        resolve(Number.isInteger(answer.status) ? answer : null);
      } catch {
        resolve(null);
      }
    });
    child.stdin.on("error", () => {});
    child.stdin.end(`${JSON.stringify(request)}\n`);
  });
}

/** One authenticated call; the session the answer refreshes replaces the one held. */
async function call(method, path, body) {
  const answer = await exchange({ kind: "http", method, path, session, ...(body !== undefined ? { body } : {}) });
  if (answer?.session) {
    session = answer.session;
    held.add(session);
  }
  return answer;
}
const parsed = (answer) => { try { return JSON.parse(answer.body); } catch { return null; } };
/** The Manager's own refusal, its code and message, where it answered one. */
const refusal = (answer) => {
  const body = parsed(answer);
  return `${answer.status}${body?.code ? ` ${body.code}` : ""}${body?.message ? `: ${body.message}` : ""}`;
};

/** Read the run until `until` holds of it, printing each change of its status and steps. Lost relays
 *  and the Manager's own 5xx are waited out RETRIES times in a row; anything else stops the watch. */
async function watch(runId, until) {
  let failures = 0;
  let last = "";
  for (;;) {
    const answer = await call("GET", `/api/runs/${encodeURIComponent(runId)}`);
    const run = answer?.status === 200 ? parsed(answer) : null;
    if (answer?.status === 401) stop(`the watch on run ${runId} stopped: the session is no longer valid (expired or revoked), and no other is minted. The run goes on in the Manager: open /runs/${runId}`, EXIT.watchStopped);
    if (answer && answer.status !== 200 && answer.status < 500) stop(`the watch on run ${runId} stopped: the Manager answered ${refusal(answer)}. Open /runs/${runId}`, EXIT.watchStopped);
    if (!run || typeof run.status !== "string") {
      failures += 1;
      if (failures > RETRIES) stop(`the watch on run ${runId} stopped: ${failures} reads in a row got no answer. The run goes on in the Manager: open /runs/${runId}`, EXIT.watchStopped);
      await sleep(POLL_MS);
      continue;
    }
    failures = 0;
    const steps = Array.isArray(run.steps) ? run.steps.map((s) => `${s.name} ${s.status}`).join(", ") : "";
    const now = `${run.status}${steps ? ` (${steps})` : ""}`;
    if (now !== last) say(`run ${runId}: ${now}`);
    last = now;
    if (until(run.status)) return run;
    await sleep(POLL_MS);
  }
}

/** One read of the Manager that must answer: repeated across a lost relay and the Manager's 5xx, RETRIES
 *  times in a row. Where it cannot be answered the script ends with `code` and `ending` after the reason. */
async function read(path, what, code, ending) {
  let failures = 0;
  for (;;) {
    const answer = await call("GET", path);
    const body = answer?.status === 200 ? parsed(answer) : null;
    if (body !== null) return body;
    if (answer?.status === 401) stop(`${what}: the session is no longer valid (expired or revoked), and no other is minted${ending}`, code);
    if (answer && answer.status !== 200 && answer.status < 500) stop(`${what}: the Manager answered ${refusal(answer)}${ending}`, code);
    failures += 1;
    if (failures > RETRIES) stop(`${what}: ${failures} reads in a row got no answer${ending}`, code);
    await sleep(POLL_MS);
  }
}

/** The x.y of a release or image tag: its version line. */
const lineOf = (tag) => /^(\d+\.\d+)\./.exec(tag)?.[1];
/** A text as a pattern that matches only itself. */
const literal = (text) => text.replace(/[^A-Za-z0-9]/g, "\\$&");

/** One look at the following tenants in `pending`: each is landed, failed, still waited for, left to
 *  Move to line, or renders no part of the unit. `standing` is the release they must run; `since` is when
 *  the release run started, and absent before the release request, where no Versions run can follow it
 *  yet and the live Application is the proof for a tenant without one. */
async function look(pending, unit, standing, since, on) {
  const seen = { landed: [], failed: [], waiting: [], left: [], unrelated: [] };
  if (pending.length === 0) return seen;
  const tag = standing.tag;
  if (!/^[0-9a-f]{40}$/.test(standing.commit ?? "")) stop(`the Manager names no full commit for the release of ${unit}, so the image tag its tenants run cannot be told${on.ending}`, on.code);
  const image = `${tag}-${standing.commit.slice(0, 7)}`;
  for (const tenant of pending) {
    const view = await read(`/api/tenants/${encodeURIComponent(tenant.id)}/versions?offered=false`, `the versions of tenant ${tenant.id} could not be read`, on.code, on.ending);
    const part = (view.parts ?? []).find((p) => p.name === unit);
    if (!part) {
      seen.unrelated.push(tenant);
      continue;
    }
    if (!Array.isArray(part.runs)) stop(`the versions of tenant ${tenant.id} carry no Versions runs for ${unit}, so a run that moved it to ${image} cannot be told from one that did not${on.ending}`, on.code);
    const running = part.running ?? [];
    const runsImage = running.length > 0 && running.every((r) => r === image);
    if (running.length > 0 && !runsImage && running.every((r) => lineOf(r) !== lineOf(tag))) {
      seen.left.push({ tenant, line: lineOf(running[0]) });
      continue;
    }
    const moved = part.runs.find((r) => r.tag === image);
    const after = moved !== undefined && since !== undefined && moved.creation > since;
    const note = { tenant, ...(moved ? { run: moved.id } : {}) };
    if (moved && TERMINAL.has(moved.status) && moved.status !== "succeeded" && (after || runsImage)) {
      seen.failed.push({ ...note, status: moved.status });
    } else if (moved && !TERMINAL.has(moved.status)) {
      seen.waiting.push({ ...note, why: `its Versions run ${moved.id} is ${moved.status}` });
    } else if (!runsImage) {
      seen.waiting.push({ ...note, why: `it runs ${running.join(", ") || "no release"}, and no Versions run after this release started has moved it to ${tag}` });
    } else if (after) {
      seen.landed.push({ ...note, line: `runs ${tag} (Versions run ${moved.id} succeeded)` });
    } else if (since !== undefined) {
      seen.waiting.push({ ...note, why: "it records the release, and no Versions run followed this release to prove it" });
    } else {
      const live = await read(`/api/tenants/${encodeURIComponent(tenant.id)}/live`, `the live state of tenant ${tenant.id} could not be read`, on.code, on.ending);
      if (live.argo?.ok === true && live.argo.sync === "Synced" && live.argo.health === "Healthy") seen.landed.push({ ...note, line: `already runs ${tag}` });
      else seen.waiting.push({ ...note, why: "it records the release, and its Application is not Synced and Healthy" });
    }
  }
  return seen;
}

/** The active tenants of `stage` that follow releases. */
async function followingTenants(stage, on) {
  const all = await read("/api/tenants", "the tenants could not be read", on.code, on.ending);
  if (!Array.isArray(all)) stop(`the tenants could not be read: the Manager answered no list${on.ending}`, on.code);
  return all.filter((t) => t.stage === stage && t.status === "active" && t.suspended === false && t.followReleases === true);
}

const failedLine = (f) => `tenant ${f.tenant.id}: its Versions run ${f.run} ${f.status}: open /runs/${f.run}`;

/** Before the release request: a tenant that records the tag while the run that moved it failed ends
 *  the script. The tenants that already run the tag are printed and
 *  returned, because the follower plans no Versions run for them and the wait after the release would
 *  never see one. */
async function refuseHeldTenants(stage, unit, standing) {
  const on = { code: EXIT.unavailable, ending: "; nothing was planned" };
  const seen = await look(await followingTenants(stage, on), unit, standing, undefined, on);
  if (seen.failed.length > 0) stop(`${seen.failed.map(failedLine).join("; ")}; the release would change nothing for it, so nothing was planned`, EXIT.failed);
  for (const l of seen.landed) say(`tenant ${l.tenant.id}: ${l.line}`);
  return seen.landed.map((l) => l.tenant.id);
}

/** After the run succeeded: wait until every following tenant at `stage` that renders `unit`, except
 *  those in `alreadyRunning`, runs the stage's release tag, and print one line for each. The tag the
 *  stage pins must be the release `wanted` describes, or another release reached the stage and the
 *  tenants would be waited for under this run's name. */
async function waitForFollowing(stage, unit, since, runId, wanted, alreadyRunning) {
  const on = { code: EXIT.watchStopped, ending: `. The run ${runId} succeeded; whether the following tenants run it is not known: open /runs` };
  if (typeof since !== "number") stop(`run ${runId} succeeded, but the Manager names no time it started, so the Versions runs that followed it cannot be told: open /runs`, on.code);
  const standing = (await read(`/api/units/${unit}/release?stage=${stage}`, `the release ${stage} runs of ${unit} could not be read`, on.code, on.ending)).standing;
  if (typeof standing?.tag !== "string") stop(`the Manager names no release that ${stage} runs of ${unit}${on.ending}`, on.code);
  const tag = standing.tag;
  if (!wanted.pattern.test(tag)) stop(`run ${runId} succeeded, but ${stage} pins ${unit} at ${tag}, and this release is ${wanted.text}: another release of ${unit} reached ${stage}, so the tenants are not waited for. Open /runs`, EXIT.failed);
  let pending = (await followingTenants(stage, on)).filter((t) => !alreadyRunning.includes(t.id));
  const deadline = Date.now() + FOLLOW_SECONDS * 1000;
  let rendering = alreadyRunning.length > 0;
  let announced = false;
  for (;;) {
    const seen = await look(pending, unit, standing, since, on);
    rendering = rendering || seen.unrelated.length < pending.length;
    for (const l of seen.landed) say(`tenant ${l.tenant.id}: ${l.line}`);
    for (const l of seen.left) say(`tenant ${l.tenant.id}: stays on line ${l.line}, and ${tag} is on line ${lineOf(tag)}; Move to line on /tenants/${l.tenant.id}, not waited for`);
    if (seen.failed.length > 0) stop(seen.failed.map(failedLine).join("; "), EXIT.failed);
    pending = seen.waiting.map((w) => w.tenant);
    if (pending.length === 0) break;
    if (!announced) say(`waiting for ${pending.length} following tenant${pending.length === 1 ? "" : "s"} at ${stage} to run ${tag}: ${pending.map((t) => t.id).join(", ")}`);
    announced = true;
    if (Date.now() >= deadline) stop(`${seen.waiting.map((w) => `${w.tenant.id} (${w.why})`).join("; ")} did not run ${tag} within ${FOLLOW_SECONDS} seconds. The run ${runId} succeeded: open /runs`, EXIT.watchStopped);
    await sleep(POLL_MS);
  }
  if (!rendering) say(`no following tenant at ${stage} renders ${unit}`);
}

const args = process.argv.slice(2);
const [DOOR, UNIT] = args;
const PROD_TO_TEST = args.length === 3 && args[2] === "--prod-to-test";
if (!(PROD_TO_TEST || args.length === 6)) stop(USAGE, EXIT.usage);
if (!/^[a-z_][a-z0-9_-]*@[A-Za-z0-9.-]+$/.test(DOOR)) stop(`the door must be <user>@<host> (got '${DOOR}')`, EXIT.usage);
if (!/^[a-z0-9-]+$/.test(UNIT)) stop(`'${UNIT}' is no unit name`, EXIT.usage);
const POLL_MS = setting("RELEASE_UNIT_POLL_SECONDS", 10) * 1000;
/** How long one exchange may take before its relay counts as lost: a read is repeated, a mutation is not. */
const EXCHANGE_MS = setting("RELEASE_UNIT_EXCHANGE_SECONDS", 120) * 1000;
const RETRIES = setting("RELEASE_UNIT_RETRIES", 30);
/** How long the following tenants may take to run the tag after the release run succeeded. */
const FOLLOW_SECONDS = setting("RELEASE_UNIT_FOLLOW_SECONDS", 1800);
let release;
/** The release tag this run puts on the stage, as a pattern and as the words that name it. */
let wanted;
let alreadyRunning = [];
if (!PROD_TO_TEST) {
  const [, , stage, channel, version, commit] = args;
  if (!["dev", "test", "prod", "none"].includes(stage)) stop(`the stage must be dev, test, prod or none (got '${stage}')`, EXIT.usage);
  if (!["alpha", "beta", "stable"].includes(channel)) stop(`the channel must be alpha, beta or stable (got '${channel}')`, EXIT.usage);
  if (!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.([0-9]{3}|0|[1-9][0-9]*)$/.test(version)) stop(`the version must be x.y.z (got '${version}')`, EXIT.usage);
  if (!/^[0-9a-f]{40}$/.test(commit)) stop(`the commit must be its full sha, 40 lowercase hex digits (got '${commit}')`, EXIT.usage);
  release = { stage: stage === "none" ? null : stage, channel, version, commit };
  wanted = { pattern: new RegExp(`^${literal(`${version}-${channel}-`)}[0-9]{14}$`), text: `${version}-${channel}-<14 digits>` };
}

const minted = await exchange({ kind: "mint" });
const mintedSession = minted?.status === 200 ? parsed(minted)?.session : undefined;
if (typeof mintedSession !== "string" || mintedSession === "") stop(`no session was minted over the Manager's admin socket through ${DOOR} (${minted ? `the socket answered ${minted.status}` : "the relay gave no answer"}); nothing was planned`, EXIT.unavailable);
session = mintedSession;
held.add(session);

if (PROD_TO_TEST) {
  const offer = await call("GET", `/api/units/${UNIT}/release?stage=prod`);
  if (!offer) stop(`the prod release of ${UNIT} could not be read: the relay gave no answer; nothing was planned`, EXIT.unavailable);
  const standing = offer.status === 200 ? parsed(offer)?.standing : undefined;
  if (!standing) stop(`the prod release of ${UNIT} could not be read: the Manager answered ${refusal(offer)}; nothing was planned`, EXIT.failed);
  say(`source: prod release ${standing.tag} of ${UNIT} on ${standing.commit}`);
  release = { stage: "test", channel: standing.channel, version: standing.version, commit: standing.commit, sourceStage: "prod", sourceTag: standing.tag };
  wanted = { pattern: new RegExp(`^${literal(standing.tag)}$`), text: standing.tag };
  alreadyRunning = await refuseHeldTenants("test", UNIT, standing);
}

const planned = await call("POST", `/api/units/${UNIT}/release`, release);
if (!planned) stop(`the release request of ${UNIT} got no answer, so whether the Manager made a run of it is not known; it is not sent again. Read the Runs page`, EXIT.watchStopped);
const runId = planned.status === 201 ? parsed(planned)?.runId : undefined;
if (typeof runId !== "string") stop(`the release of ${UNIT} was refused: the Manager answered ${refusal(planned)}`, EXIT.failed);
say(`run: ${runId}`);

const plan = await watch(runId, (status) => status !== "planning");
if (plan.status !== "planned") stop(`run ${runId} was refused at its plan (${plan.status}): open /runs/${runId} for why`, EXIT.failed);
const steps = plan.steps.map((s) => s.name);
if (PROD_TO_TEST && steps.join(",") !== "put-release") stop(`run ${runId} plans ${steps.join(", ")}, and a release from prod to test is the one put-release; it is not approved. Discard it on /runs/${runId}`, EXIT.failed);
if ((plan.requiredSecrets ?? []).length > 0) stop(`run ${runId} asks for secrets to be typed, which this script does not do; it is not approved. Open /runs/${runId}`, EXIT.failed);

const approved = await call("POST", `/api/runs/${encodeURIComponent(runId)}/approve`, {});
if (!approved) say(`run ${runId}: the approval got no answer; it is not sent again, and the run is read`);
else if (approved.status < 200 || approved.status > 299) stop(`run ${runId} was not approved: the Manager answered ${refusal(approved)}. Open /runs/${runId}`, EXIT.failed);

const ended = await watch(runId, (status) => TERMINAL.has(status) || (status === "planned" && !approved));
if (ended.status === "planned") stop(`run ${runId} stands planned: the approval did not reach it, and it is not sent again. Approve it on /runs/${runId}`, EXIT.failed);
if (ended.status !== "succeeded") stop(`run ${runId} ${ended.status}: open /runs/${runId}`, EXIT.failed);
say(`run ${runId} succeeded`);
if (release.stage !== null) await waitForFollowing(release.stage, UNIT, ended.startedAt, runId, wanted, alreadyRunning);
