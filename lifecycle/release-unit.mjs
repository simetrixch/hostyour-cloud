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
// row. Only a succeeded run exits 0; the run id is printed as soon as it is known and named in every
// later line.
import { spawn } from "node:child_process";

const USAGE = [
  "usage: lifecycle/release-unit.sh <user@master-host> <unit> --prod-to-test",
  "       lifecycle/release-unit.sh <user@master-host> <unit> <dev|test|prod|none> <alpha|beta|stable> <x.y.z> <commit>",
].join("\n");
/** Exit codes: a run that did not succeed, a usage error, a Manager that could not be reached, a watch that stopped. */
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
let release;
if (!PROD_TO_TEST) {
  const [, , stage, channel, version, commit] = args;
  if (!["dev", "test", "prod", "none"].includes(stage)) stop(`the stage must be dev, test, prod or none (got '${stage}')`, EXIT.usage);
  if (!["alpha", "beta", "stable"].includes(channel)) stop(`the channel must be alpha, beta or stable (got '${channel}')`, EXIT.usage);
  if (!/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.([0-9]{3}|0|[1-9][0-9]*)$/.test(version)) stop(`the version must be x.y.z (got '${version}')`, EXIT.usage);
  if (!/^[0-9a-f]{40}$/.test(commit)) stop(`the commit must be its full sha, 40 lowercase hex digits (got '${commit}')`, EXIT.usage);
  release = { stage: stage === "none" ? null : stage, channel, version, commit };
}

const minted = await exchange({ kind: "mint" });
const mintedSession = minted?.status === 200 ? parsed(minted)?.session : undefined;
if (typeof mintedSession !== "string" || mintedSession === "") stop(`no session was minted over the Manager's admin socket through ${DOOR} (${minted ? `the socket answered ${minted.status}` : "the relay gave no answer"}); nothing was planned`, EXIT.unavailable);
session = mintedSession;
held.add(session);

if (PROD_TO_TEST) {
  const offer = await call("GET", `/api/units/${UNIT}/release?stage=prod`);
  if (!offer) stop(`the release prod runs of ${UNIT} could not be read: the relay gave no answer; nothing was planned`, EXIT.unavailable);
  const standing = offer.status === 200 ? parsed(offer)?.standing : undefined;
  if (!standing) stop(`the release prod runs of ${UNIT} could not be read: the Manager answered ${refusal(offer)}; nothing was planned`, EXIT.failed);
  say(`source: prod runs ${standing.tag} of ${UNIT} on ${standing.commit}`);
  release = { stage: "test", channel: standing.channel, version: standing.version, commit: standing.commit, sourceStage: "prod", sourceTag: standing.tag };
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
