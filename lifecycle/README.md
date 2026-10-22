# lifecycle

The life of one installation: the GitHub App it acts under, the act that brings it into being, every
release put on it afterwards, the registration one installation holds for another taken off again, and
what an installation whose machines are gone left outside them taken down. Everything here runs from
an operator's own machine — Linux or macOS, and Windows through WSL — and nothing here runs in a cluster.

**The subject is an installation, not a delivery.** A first install delivers nothing; it creates. The
acts below share a subject rather than a purpose, which is why they stand in one folder.

## The acts

| act | what it does |
|---|---|
| `create-github-app.sh` | creates the platform's GitHub App in the customer's organisation, installs it there, and writes `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID` and `GITHUB_APP_PRIVATE_KEY` into the config; two clicks in the browser stay |
| `install-machine.sh` | installs a first master from zero: a machine, a branch, a cluster and the platform services on it |
| `release-platform.sh` | with an fqdn, cuts a release of the platform tree and pins ONE installation to it; without one, cuts the release and pins nothing, which is what a first machine names as `PLATFORM_REF` |
| `regenerate-install-branch.sh` | brings an installation onto the release its own map is pinned to |
| `remove-slave-from-master.sh` | takes ONE slave's registration off the master it stands on |
| `abandon-installation.sh` | takes down what an installation whose machines are gone left outside them: the DNS records it wrote, its install branches on origin and its books branch in the deploy repository; the config stays |
| `master-backup.sh <config> [master\|plane]` | takes the stores of one set, sealed, to the storage box, and reads the backup back from it before it ends. The set `master`, which a call without a set takes, is a master's stores and Vault's quorum under `<fqdn>/master/<id>/`, holding the Manager's runs while it takes them; the set `plane` is Plane's database and files alone under `<fqdn>/plane/<id>/`, holding nothing. One run at a time on a machine, whichever the set (a second ends 75). The read-back ends a read that stands still or falls behind the rate it measured on that same read, or that has read every byte and does not end |
| `master-restore.sh` | stages one of those backups on a bare machine, so that `install-machine` then installs the same installation onto it — same identity, same branch, its stores standing; it puts the pinned rclone on the machine first, from the owner's mirror or, with `--rclone-package <local .deb>`, from the package the operator kept |
| `plane-restore.sh <config> [<id>]` | puts one backup of the set `plane` back into the cluster that stands: without an id it lists the backups under `<fqdn>/plane/` and ends 64; with one it fetches the backup, refuses before it stops anything a backup whose checksums, FQDN, stage or set do not hold, one that misses an archive, and a workload or a volume it cannot find, then stops Plane's database and its object store one after the other, replaces the content of their volumes with the backup's, starts each again with the replicas it had and waits until it reads ready, and ends `RESTORED <id>`. It takes the lock the backup takes |
| `status.sh` | answers which release each installation stands on, and what the trunk carries since |
| `release-unit.sh` | releases ONE unit through the Manager, as the Release dialog does, with no click: it plans the release over the Manager's admin access, approves the plan and watches the run to its end; `--prod-to-test` puts the exact prod release on test; the stage `none` releases a library or the platform, which have no stage, and names the installations a platform release is placed on |
| `check-forgejo-ssh.sh` | asks the SSH port an installation announces for Forgejo (its install branch's `SSH_PORT`, 23 today) for an SSH banner, from where it runs; run it from outside the installation's network, in a clone whose origin carries the install branch (exit 69 otherwise). `status.sh` calls it as one `forgejo-ssh:` row of every installation whose branch runs Forgejo, and `install-machine.sh` at its end after an installation that ended well: green on a banner, RED on none, `not asked` where it could not ask; 66 (no Forgejo on the branch) is no row. Tekton does not call it: it runs inside the network |
| `create-origin-pull-certificate.sh` | makes the CA and the client certificate Cloudflare presents to the origins of proxied hosts, and writes `CLOUDFLARE_ORIGIN_PULL_CA`, `CLOUDFLARE_ORIGIN_PULL_CERTIFICATE` and `CLOUDFLARE_ORIGIN_PULL_PRIVATE_KEY` into the config; a second run is a rotation |
| `apply-cloudflare-zone-security.sh` | previews or applies, and reads back, the Cloudflare Free controls of the installation's two zones, among them the minimum TLS version of 1.2 and Email Obfuscation off |
| `plan-installation-domain.sh` | plans and dry-runs proposed hostname changes across domain zones: reads every cluster map on a freshly fetched books branch, optionally probes machine names and Ingress/IngressRoute over ssh, and prints proposed hostname changes and coverage without altering remote state |

`scripts/test.sh` runs their remote fixture checks.

**Six files here are not a person's entry point.** `driver.sh` is the installation itself,
`regenerate-driver.sh` the regeneration, `remove-slave-driver.sh` the removal, `master-backup-driver.sh`
the backup of either set, `master-restore-driver.sh` the staging of a restore and `plane-restore-driver.sh`
the restore of Plane's stores: all six run ON THE MACHINE, and the
launcher beside each carries it over the session it opens. None of them is started by hand.

## The order the acts stand in

A release is TWO acts and they are separate on purpose. `release-platform` puts the tag on the remote,
waits until the owner's mirror serves every image the tree at the tag lists (`scripts/list-mirror-images.sh`,
copied there by the publish run the tag starts, read back by digest without a login) and every
tool and chart its `clusters/platform/mirror-sources.table` lists (`scripts/list-mirror-sources.sh`, read back by
the manifest of its tag, which must name one layer of the row's sha256), for `RELEASE_MIRROR_WAIT` seconds at
most, 7200 unless set. Then it writes `release: <tag>` into
`clusters/active/<fqdn>.yaml` on the installation's own branch — and stops. The installation still
stands on the state before it: that line RECORDS which state it should stand on and carries none of
it, because every source of every Application this platform generates targets the install branch.
`regenerate-install-branch` is what brings the branch to the pin, by merging the tag into it. It
reads the ref off that same line rather than being told it again, so the pin and the regeneration
are one statement instead of two that can disagree. Between the two acts somebody can read what the
pin now says and stop.

# Creating the platform's GitHub App

```
bash lifecycle/create-github-app.sh lifecycle/config.apps4.env
bash lifecycle/create-github-app.sh lifecycle/config.apps4.env acme      # the organisation named, not read off DEPLOY_REPO
```

The three answers `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID` and `GITHUB_APP_PRIVATE_KEY` of the
config are what the Manager creates a tenant's own apps repository under, and no API creates a GitHub
App from nothing or installs one on an organisation. This act does what an API can do and leaves the
two clicks GitHub keeps for a person. It starts a listener on `127.0.0.1`, opens the browser on a page
that posts the App's manifest to the organisation's new-App page — the name `<organisation>-platform-manager`,
the homepage `https://manager.<UNIT_APEX>`, the six repository permissions `administration`,
`contents`, `webhooks` and `workflows` at write and `metadata` and `packages` at read,
no webhook, private — and waits. No `actions`: the Manager starts no workflow, it writes a release's tag and
deploy ref itself. `packages` at read does NOT let the App's token install a private npm package: GitHub
grants an installation token no access to a private package whatever the App's permissions say, and
a build reads its npm packages from the build plane's registry with the registry's pull identity,
while the App stays the identity of every repository.
The first click is GitHub's own **Create GitHub App**. GitHub sends the browser back with a code, the
act turns the code into the App, refuses when the answered permissions are not the six asked, and
writes `GITHUB_APP_ID` and `GITHUB_APP_PRIVATE_KEY` into the config at once, in place, the key as one
line with `\n` for each line break. It then opens the App's installation page for the second click,
**Install** with **All repositories**, asks GitHub every five seconds with a JWT signed by the key
until the installation stands, refuses one made on selected repositories, and writes
`GITHUB_APP_INSTALLATION_ID`. The organisation is the owner of `DEPLOY_REPO` unless named as the
second argument. The browser is `$BROWSER` where that is set, and the platform's own opener otherwise.

The key is written the moment the App stands, because it exists in that run's memory and in the
config and nowhere else. So a run that ends between the two clicks — the ten-minute bound, a closed
browser, an installation on selected repositories — leaves a config carrying the App's id and key,
and the next run finds them, skips the creation, and installs. A config carrying all three refuses.
The config is asked before the browser opens whether anybody but the owner can read it, and again
after each write, with the same guard every launcher applies.

# Releasing a unit by script

```
bash lifecycle/release-unit.sh <user@master-host> <unit> --prod-to-test
bash lifecycle/release-unit.sh <user@master-host> <unit> <dev|test|prod|none> <alpha|beta|stable> <x.y.z> <commit> [--installation <fqdn>]...
```

The first form reads the prod release (`GET /api/units/<unit>/release?stage=prod`: its tag,
version, channel and full commit) and puts exactly that release on test. The prod release is the
release prod has put: it does not say that a tenant at prod runs it, and a tenant that has not adopted
it yet does not block the copy. The Manager plans it as the
`put-release` step, with a step of the unit's own where the unit has one (digita-post re-attests its SMTP
entry), and reads prod again before it pushes the deploy ref, so a prod that moved in between writes
nothing. The script approves every plan of this form that mints and builds nothing, and refuses one with
the step `mint-release` or `watch-release-build`, naming it. The second form plans the
release the dialog would plan for that stage, channel, version and full commit.

The second form always sends the installations the release is placed on, as `installations` in the
release request: `[]` when no `--installation <fqdn>` is given, which publishes the release and places it
nowhere, and the FQDNs in the order they were given otherwise. Only the platform's release, which has no
stage (`none`), is placed. A pair that is malformed or trailing, an FQDN given twice and any
`--installation` beside `--prod-to-test` end the script with 64 before it calls the Manager. The Manager
decides the rest at its plan: the repository, the channel and its stages, the installation's identity
and how many it places on. The one master it holds is the only installation it places a release on, so
repeating the flag does not promise more than one.

After the plan, before any approval, the script reads `installations` of `GET /api/runs/<run-id>`, the
selection the plan froze, and compares it with the request: an array of strings with the same names in
the same order, `[]` included. A Manager that strips the field (one from before it), a `null`, a value
that is no list, an added, repeated, omitted, changed or reordered name end the script with the plan
unapproved, still planned, and the run's page named. The comparison comes before the stop for secrets, so
it is reported even where the plan also asks for the elevation password. A plan that does ask for it,
which a placement does, is left planned for the owner's approval page; the script has no password
argument, file or environment setting, and approves nothing that needs one.

The script runs on the operator's machine and needs `node` and `ssh`. Every exchange with the
Manager is one `ssh <user@master-host> microk8s.kubectl exec -i` into the Manager's container
(namespace `manager`, deployment `manager`), where the container's own `node` relays one request to
the admin socket or to the Manager's port and ends. It mints one session over the admin socket,
keeps it in its own memory, and never prints it, passes it as an argument or writes it to a file.
It reads no config file and asks for no password. A plan or an approval whose answer is lost is not
sent again; a read is repeated, so a rollout of the Manager does not end the watch.

It prints the run id as soon as the Manager names it, then each change of the run's status and
steps. The run is the one `/runs/<run-id>` shows in the Manager.

A succeeded run proves only that the stage pin stands. The tenants that follow releases move
afterwards, each in its own Versions run, and that run can fail. So at a stage (not `none`) the
script then reads the release the stage has put, lists the active tenants of the stage that follow
releases, and waits until each one that renders the unit runs it. It prints one line per tenant. The
image tag of the release is its tag and the first seven digits of its commit.

A tenant is judged by its own reads and never by the list of all runs. `parts[].runs` in
`GET /api/tenants/<id>/versions?offered=false` name the Versions run that moved the part to an image
tag, and `versions` in `GET /api/tenants/<id>/live` names the tags the tenant's Application last
rendered. A tenant whose part records the image tag has landed when its Application renders that tag
for every build of the part, whatever its Versions run ended as. Otherwise it has landed when the
Versions run that moved the part to the image tag ended `succeeded` after the release run started; the
Manager ends that run only once ArgoCD rendered the versions. The record of the versions alone proves
nothing, because it turns when the pin is written, so a tenant with neither proof is not landed and is
named when the wait runs out. A Versions run that moved nothing to the image tag is not a run of this
release and is never read: not one the follower discarded because its plan changed nothing, not one
that moved only the members, not one that moved another tag. The script keeps waiting for the run
that moves the tag. A run that moved the part to the image tag and ended `failed` or `cancelled` ends
the script with exit 1 and that run's `/runs/<id>`, unless the Application renders the tag; it counts
when it was created after the release run started or the tenant records the tag. Where the Manager
names no `runs` for the part, or no `versions` for the Application, the script stops with exit 75 (69
before the release request) and says which, and it never reads the newest run in their place. The
release the stage pins must be the one the run put there (with `--prod-to-test` prod's tag, else the
version and channel given), or the script ends with exit 1 and names what the stage pins. A tenant
on another version line than the release is named with its line and left to `Move to line` on
`/tenants/<id>`; it is not waited for. When no following tenant renders the unit the script prints
`no following tenant at <stage> renders <unit>`.

A tenant whose Versions request was refused at its plan has no run of the release to wait for, and
that request can be a combined one: the follower moves the platform and the tenant's catalog bundle in
one Versions run, so a bundle release that links a website the tenant does not run holds the platform
release back with it. `GET /api/units/<unit>/release?stage=<stage>` names each such tenant in
`standing.followRefused` (tenant, refused run and the redacted reason of the run's record), and the
script reads that view again on every look of the wait. A tenant in the list that has not landed ends
the script with exit 1 and prints the tenant, the run, the reason and the run's `/runs/<id>`; the unit
release run itself may have succeeded, and the script says neither that the tenant is up to date nor
that the unit's build failed. A refusal that stood before the script started is named at the first
look, and one that appears later at the next look. It is read before the generic failure of a
Versions run, and never ahead of the proof that the tenant's Application renders the release. A
tenant that is only late, or has a Versions run under way, is still waited for. The list is required
on a stage response: a Manager that names none, or an entry without a tenant or a run, stops the
watch with exit 75, and the script never takes that for an empty list. If the stage pins another
release when the view is read again, the script ends with exit 1 and names what it pins; the list
belongs to the release the view names. With `--prod-to-test` the prod view is the source of the copy
only: the refusals it names belong to prod's tenants and are not applied to the tenants at test.

With `--prod-to-test` the same rule is read before the release request: a tenant that records the
tag, whose Application does not render it and whose Versions run that moved it to the tag failed or
was cancelled ends the script with exit 1 and that run's `/runs/<id>`, and nothing is planned,
because planning the release again would change nothing for it. A tenant that records the tag and
whose Application renders it already runs the tag, whatever its Versions run ended as: it is printed
there and not waited for.

| exit | what it means |
|---|---|
| 0 | the run succeeded |
| 1 | the plan was refused, or the run failed or was cancelled, or a plan or an approval did not take, or the Versions run that moved a following tenant to the tag failed or was cancelled, or the Manager names a following tenant's Versions request as refused at its plan, or the stage pins another release than the one waited for; the run, where there is one, is named |
| 64 | the arguments are not one of the two forms, or a setting below is not a whole number |
| 69 | `node` or `ssh` is missing, no session could be minted over the admin socket, or the following tenants, their Versions runs or their rendered versions could not be read before the release request; nothing was planned |
| 75 | the watch stopped while the run may go on: the session expired or was revoked, the relay gave no answer too often in a row, or a release request got no answer; or the run succeeded and a following tenant did not run the tag within `RELEASE_UNIT_FOLLOW_SECONDS`, or could not be read, or the Manager named no Versions runs, rendered versions or list of refused follows for it; the run, where there is one, is named |

`RELEASE_UNIT_POLL_SECONDS` (10) is the pause between two reads of the run, and
`RELEASE_UNIT_RETRIES` (30) the number of reads in a row that may get no answer before the watch
stops, and `RELEASE_UNIT_EXCHANGE_SECONDS` (120) how long one exchange may take before it counts as
one with no answer. `RELEASE_UNIT_FOLLOW_SECONDS` (1800) is how long the following tenants may take
to run the tag after the run succeeded; `0` is one look.

# Installing a first master

A first master, installed from zero, from an operator's own machine.

## What this is, and what it is not

It is a **driver**. It runs no step and decides nothing an answer should decide: it puts the two
things a program cannot put there itself — the engine and the programs checkout — and then invokes the five
programs that make a master, each of them three times.
[`clusters/platform/install-order.yaml`](../clusters/platform/install-order.yaml) states that
division in its own words:

> THIS FILE STATES THE ORDER. IT DOES NOT RUN IT. A driver reads the sequence and invokes the
> programs itself.

**`driver.sh` carries its own copy of that sequence and does not read the file.** So does the
Manager, in TypeScript. Three carriers of one fact, and the one written to be the answer is the one
no RUNNER reads; both `driver.sh` and `install-order.yaml` say so in their own headers rather than
leaving the drift to be discovered.

The file is read, though, and by two programs: the Manager's boot check `install-order.agrees`, which
holds its own step lists against it, and `ansiwise-client`, which fetches it to show an operator the
programs of the role being installed. So a row changed there changes what a person is SHOWN and what
one check compares, and changes no run — which is the whole of what "nothing reads it" used to say
wrongly.

`ansiwise-client` is the other driver, and the one to prefer when a person is at a screen: it shows
each step, asks before it acts, and can stop. IT DRIVES A MACHINE THIS TOOL HAS ALREADY INSTALLED —
it opens one that already carries the engine and puts nothing on one that does not
(`ansiwise-client#34`). This is what makes a first master out of a bare one, for the operator who
wants one command, one transcript, and every line of it kept.

## Where it stops, and why the sequence is five and not six

`install-order.yaml` names a sixth program for a master, `onboard-manager`, and it is deliberately
not run here. It onboards this platform's own Manager **as a consumer**, over the route every other
consumer takes — which makes it an onboarding, and onboarding is not this tool's to do.

What a master is without it: a machine, a branch, a cluster, and the platform services on it —
including the Manager itself, which `deploy-platform-services` puts there. Onboarding it as a
consumer is then the first thing done **in** the Manager, by hand, and not the last thing done to it
by a script.

## The three files

| file | where it runs | what it does |
|---|---|---|
| `driver.sh` | **on the machine** | the whole installation: preconditions, engine, programs checkout, the six programs |
| `install-machine.sh` | the operator's machine | checks the config, opens one session, keeps every line, fetches the records |

`install-machine.sh` asks whether the config is protected by its mode, read with `stat`: 600 or 400
passes, and any other mode is refused with the `chmod` that closes it.

The launcher is thin on purpose. **Everything is fetched by the machine itself, and all three
are public**: the pin out of the platform repository, the two executables out of the release, the
programs checkout out of `hostyour-deploy`, the repository the deployment programs stand in. Nothing is
carried from the operator's disk, so what stands on the machine afterwards is what the repositories
say rather than what somebody's checkout happened to hold.

**The owner's master is the one machine that cannot reach the release**, because the registry the
release is served from is its own zot, which does not stand while it is installed, on a first
installation as on a restore. Every image of the platform is pulled from that zot too, zot's own
among them. `driver.sh` has no other source for the engine and the images of that machine, so a first
installation or a restore of it stops at the fetch of the engine, and the message says so.

## Running it

```
cp config.example.env ~/apps4.env     # NOT inside a git working tree
$EDITOR ~/apps4.env                   # one line per value; the credentials are marked
chmod 600 ~/apps4.env

./install-machine.sh ~/apps4.env
```

**No options.** An installation is a great many statements, and a command line long enough to carry
them is one nobody can read back, nobody can diff, and whose every value stands in the machine's
process listing. One file states the whole installation.

**`NAME='value'` and not JSON**, for the reason this organisation's board tooling is the same shape:
a shell reads it with one `.` and needs no parser, no `jq` and no Python. JSON would cost every
operator a dependency, and it cannot carry the one thing that file needs most — a sentence saying
what a value is.

`config.example.env` is written by hand, so it can fall behind what the six programs declare. The
run is what names that: `compose_answers` in `driver.sh` lists, per program, every answer that
program declares and your config left out, and the engine refuses a missing REQUIRED one before the
first step. `regenerate-install-branch` reads the same file, in the same grammar, for the same
reason: what an installation is, is stated once.

## Which door it opens

The two cases this has to serve are opposites, so the launcher **asks the machine first** and needs
no flag from you:

- **A machine this platform installed** carries the operator key, and `disable-password-login` has
  shut its password door. The key is tried first, so this is the normal path and nothing is asked.
- **A machine at its birth carries no key at all.** `deploy-host`'s `install_authorized_key` row is
  what puts it there, and that row is one of the six programs this is about to run — so the very
  first session can only be a password session. Where the key is refused, `ssh` asks for the login
  password **once, on your terminal**. It is not read from the config, it is not kept, and it does
  not reach the transcript.

There is exactly one session either way, so a password is typed at most once: the config travels
inside a quoted heredoc with `driver.sh` behind it, on that session's own standard input.
`regenerate-install-branch` opens its session the same way, with `regenerate-driver.sh` behind the
same heredoc.

**A launcher with no terminal to ask on refuses rather than waits.** Started from a job or a pipe
against a machine that has no key yet, it says so and exits — a launcher that sits silently on a
prompt nobody can see is worse than one that stops.

### The host key after a restore

A restore gives a machine a **new host key**. Your `known_hosts` still carries the old one, and
`ssh` refuses — correctly, because that is also what a machine being impersonated looks like. The
launcher recognises that refusal and tells you the line that clears it:

    ssh-keygen -R apps4.example.com

A host key that is simply **unknown** is accepted and recorded (`StrictHostKeyChecking=accept-new`),
because at a machine's birth there is nothing to compare it against. A **changed** one never is.

## What it refuses, and why

- **A file other accounts can read.** Several values are credentials: the elevation password of the
  machine, repository *write* tokens, a repository read token, a DNS token, a storage password and
  a registry token.
- **A file standing inside a git working tree.** The mistake is made once and cannot be taken back —
  a token that reached a remote must be rotated.
- **Any line that is not a comment or `NAME='value'`.** The config is READ BY THE SHELL on the
  machine, so a line that is not an assignment is a command that would run there with the operator's
  own rights. The five launchers and the five drivers apply the same test, and the refusal names
  each offending line by its number, and never quotes the line, because it may be a credential with
  a closing quote forgotten. The `NAME` is added only where the line begins with it directly before
  `=` and it is a key of `config.example.env`; a token that is no key, such as a bare
  `GEZDGNBVGY3TQOJQ====` or a line inside a quote opened on an earlier line, is never printed. The
  launchers share `require-config-assignments.sh`, which reads the keys from `config.example.env`
  beside it and names numbers only when that file is missing. The drivers run on the machine, where
  no example can be read, so they name numbers only. Each driver carries the same function, which
  `test.sh` holds byte-equal to the sibling's.
- **An apostrophe in any value.** That test refuses it as a side effect, and it would break the run
  in any case: a template slot standing inside quotes has no way to say so, and the cluster map
  becomes unparseable far from the cause (`ansiwise-plugins#161`).
- **A carriage return anywhere in the config.** Notepad writes CRLF, and a `bash` on Linux reads
  that CR as part of the value — so the FQDN a certificate is issued for would end in a control
  character and nothing downstream would say why. `install-machine.sh` strips it on the way over and
  `driver.sh` refuses it on arrival.

## The one thing it does that no program does

It installs `git`, `curl` and `python3` when they are missing. `deploy-host`'s `install_packages` row
installs them too — and the programs checkout those programs are *read from* cannot be cloned without git, so
the first of them cannot run without it. That is the whole of the exception, it is reported before it
happens, and a machine already carrying all three is not touched.

## Traceability

Every line of every program reaches the operator's session as it happens, under the program and the
mode it belongs to. The same lines are written to `install-transcripts/<fqdn>-<when>/session.log`.

When the installation ends — **whether it succeeded or not** — the machine's own record of each run
is fetched beside the transcript: `run.json`, `events.jsonl`, and the `startup.log` of any run that
died before its first step. Those are what the machine wrote, not a retelling of it.

```
install-transcripts/apps4.example.com-20260827-141522/
  session.log
  20260827T141530Z-1234-abcd/{run.json,events.jsonl}
  ...
```

## Credentials

One of them is `driver.sh`'s own, and it never stands in an argument list: the elevation password,
which raises every command that has to run as root and reaches `sudo` on standard input. Fetching
the programs checkout needs none — the repository the deployment programs stand in is public, so the clone
and the fetch are made on the machine's certificate store alone. Every other credential in the
config is an answer a program declares; each lands in that program's own answer file at mode 0600,
and all of them are shredded with the config on every path `driver.sh` can end on.

The **login** password is not one of them. Where a machine still needs one, `ssh` asks for it on your
terminal and nothing here ever holds it — it is in no file, no variable and no argument, so there is
nothing to protect and nothing to rotate.

# Putting a release on an installation

```
bash lifecycle/release-platform.sh 0.8.123 stable apps4.example.com
bash lifecycle/regenerate-install-branch.sh apps4.example.com
bash lifecycle/status.sh
```

The first cuts the tag on `origin/master`, proves it is on the remote, and writes the pin into the
installation's own cluster map. It refuses before it mints anything where the branch does not exist,
where the map states no stage, or where the channel's ceiling does not admit that installation's
stage: `alpha` reaches a dev installation only, `beta` dev and test, `stable` any.

The second opens one session to the machine and runs `deploy-branch` there, then
`tailnet-record-address`, each in the three modes that gate one another. The second records the
machine's tailnet address in its map as `global.apiHost` (#242); the join is not run again. It takes the domain and nothing else — the ref comes off the pin, and the
answers come from the same `NAME='value'` config an installation was installed with. It refuses,
before it touches the machine, where the branch does not exist, where the map carries no `release:`
line, and where the tag that line names is not on the remote; every one of those refusals says that
nothing has been changed, because at every one of them nothing has.

The third only answers, and writes nothing at all.

# Backing up a master, and restoring it onto another machine

```
bash lifecycle/master-backup.sh  lifecycle/config.master.env                      # prints BACKUP <id>
bash lifecycle/master-backup.sh  lifecycle/config.master.env plane                # prints BACKUP <id>, for Plane's database and files alone
bash lifecycle/plane-restore.sh  lifecycle/config.master.env                      # lists the backups of Plane
bash lifecycle/plane-restore.sh  lifecycle/config.master.env 20260922T031500Z     # puts one back into the cluster that stands
bash lifecycle/master-restore.sh lifecycle/config.master.env                      # lists the backups
bash lifecycle/master-restore.sh lifecycle/config.master.env 20260922T031500Z     # stages one
bash lifecycle/master-restore.sh lifecycle/config.master.env 20260922T031500Z --rclone-package ~/rclone-v1.75.2-linux-amd64.deb   # the same, when the mirror is the master that is lost
bash lifecycle/install-machine.sh lifecycle/config.master.env                     # installs onto it
```

## What a master holds that nothing else holds

The install branch, the registrations and the deploy repository stand on origin; the images are rebuilt by the
release cycles; every certificate is issued again for the name. What lives on the master alone is its
stores — Vault with every unit's secrets, the Manager's database, the IdP's accounts, Headscale's
nodes, the master's own MongoDB, Redis, mail queue, dbgate and Forgejo's Git repositories — and, beside them on the
host, `secrets/vault-<stage>.txt`, the file Vault's quorum was written to once. `master-backup` takes
exactly that set: each store is stopped for its own copy and started again with the replicas it had
(a database copied under a running process is a copy with a write in flight), every archive is
sealed with `BACKUP_PASSPHRASE` before it leaves, and the whole goes to the storage box under
`<fqdn>/master/<id>/` with a manifest of checksums. Plane's database and files are not in this set: they are the set
`plane`, taken and restored on their own (the next section).

The backup holds the Manager's runs, so none of them fails because of it. First it suspends the CronJob
`release-queue` of the namespace `image-builder`, which starts every release and publish run, and waits until
that queue's last Job has ended and no release or publish run runs, read twice in a row. That wait can take up
to 65 minutes: the pipelines' timeout is one hour, and the wait adds five minutes to it. Past it the backup lets
the queue go again, stops nothing and ends 75, naming what still runs, and the Manager stays up meanwhile.
Then it stops the Manager, which pauses a run in flight between two steps and goes on with it when it starts, and
takes the stores. It starts the Manager, and then lets the queue go, only once every store it stopped reads ready
by the ready count of its workload; when a store does not, it starts neither, names the store, prints the two
commands and ends 70.
A release or publish run that a push starts during the backup waits in the queue and starts after it, and a
step the Manager's stop cuts off runs again from its start. The Manager's UI and API are down from its stop to
its start. The `app.yaml` of `manager` and of `image-builder` make Argo CD ignore `/spec/replicas` of the Manager's
Deployment and `/spec/suspend` of the queue (`respectIgnoreDifferences`), so a sync does not undo either hold.

Three things are not held. A run in `planning`, which only the streaming onboarding writes, fails at every start
of the Manager, a backup's included. A run of the Forgejo release flow lands in the namespace `forgejo-build` with
neither queue label and starts at once; no step of the Manager waits on it, and one that reads Forgejo during
Forgejo's copy may fail. A backup whose driver is killed leaves the Manager at 0 and the queue suspended, beside
the store it was copying.

## Plane's own backup, and its restore

Plane keeps its cards, comments and members in its PostgreSQL, the StatefulSet `plane-pgdb-wl` of the namespace `plane`,
and what people attach to them in its object store, `plane-minio-wl`. `master-backup.sh <config> plane` takes those two
stores alone: each is stopped for its own copy and started again with the replicas it had, every archive is sealed with
`BACKUP_PASSPHRASE`, and the three files (the two archives and a manifest of checksums that says `SET=plane` and
`STORES=2`) go to the storage box under `<fqdn>/plane/<id>/`, beside the master's folder and never inside it. It is a
short run of its own and can be repeated alone, whenever the Plane data should be safe again.

The set leaves out Plane's Valkey (`plane-redis-wl`), which holds sessions and cache, and its RabbitMQ
(`plane-rabbitmq-wl`), which holds queued tasks: neither holds a card. It holds neither the Manager's queue nor the
Manager, which reads nothing of Plane, and it seals no quorum. The two stores are copied one after the other, not at
one instant, so the database and the object store of one backup can differ by the writes between the two copies. Plane's
other pods keep running, and cannot reach a store while it is stopped for its copy. After the last copy the driver waits until each store it started
reads ready by the ready count of its workload, within `STORE_WAIT_SECONDS`, and ends 70 naming the store that does not,
before the manifest is written. The two StatefulSets render no `spec.replicas` (`scripts/plane.test.mjs` holds that), so
a sync does not write the scale to 0 back.

`plane-restore.sh <config> <id>` puts one such backup back into the cluster that stands, and is not `master-restore`,
which stages a master's backup on a bare machine. Everything written to Plane after the backup is gone afterwards, so
nobody may write to Plane while it runs. The driver takes the lock the backup takes, fetches the backup to
`/var/lib/master-backup/restore-<id>/` (root's, at mode 700) and refuses, before it stops anything: checksums that do not
hold (65), a manifest whose `FQDN`, `STAGE` or `SET` differ from this restore's (65), an archive that no checksum of the
manifest holds or that does not open with `BACKUP_PASSPHRASE` (65), a `STORES=` that is not 2 or an archive that is missing
(66), and a workload or a volume folder it cannot find (66). Then, for each of the two stores in turn, it reads the
replicas, stops the workload and waits until its pods are gone, moves the content of the volume to
`/var/lib/master-backup/restore-<id>.replaced/<namespace>--<claim>/`, opens the archive into the volume with
`--numeric-owner`, starts the workload with the replicas it had and waits until it reads ready within
`STORE_WAIT_SECONDS`. Only when both read ready does it remove the replaced content and the fetch folder, and print
`RESTORED <id>`.

A store that cannot be stopped, whose volume cannot be emptied or filled, that cannot be started again or that does not
read ready ends the restore with 70. The driver names the store, says where the replaced content and the fetched backup
stand, and prints two commands: the one that puts the old content back and starts the store again, and the one that removes
both folders when the new content is the one to keep. A restore that is killed after it began to stop stores leaves the
same two folders and the store it stood on stopped. The next restore of that backup ends 65 until both folders are looked at and removed, because the
replaced content may be the only copy of what the volume held.

## The pinned rclone

The rclone that Ubuntu 26.04 packages (1.60.1) leaves the last file of a multi-thread copy from the storage box open
after its last byte, so a read-back whose every byte arrived never ends (`lifecycle/rclone.test.sh` shows it against a
loopback SFTP server and shows the pinned release ending 0). Both drivers therefore run the release pinned in
`cliTools.rclone.version` of `clusters/platform/versions.yaml`, and the two rows of `clusters/platform/mirror-sources.table`
for the amd64 and arm64 `.deb` of that release are the only place its digest is kept.

The launcher reads the pin and the rows from the released tree it runs from (`read-rclone-pin.sh`, with plain shell: the
shape of each scalar is checked, and `lifecycle/rclone.test.sh` holds the result to `yq` and to
`scripts/list-mirror-sources.sh`), and sends them with `require-rclone.sh` through the same ssh session, between the config and the
driver, because a driver can read no sibling. A missing, doubled or malformed row ends the launcher before a session opens.
`require_rclone` of that file leaves an rclone alone that answers the pinned version both as the operator and as root, and
downloads nothing then. Otherwise it fetches the package of this machine's architecture from the owned address of its row,
with a connection limit of 20 s and a total limit of 900 s, or takes the package the launcher carried. It copies the bytes into a folder of root's,
holds that copy to the row's sha256, installs it from there with `dpkg -i`, and asks the operator's and root's rclone for the
version again. An unsupported architecture, other bytes, a failed installation or another version afterwards ends the run with a
named refusal before a store is stopped or a byte is placed; there is no fallback to an upstream address, to apt or to a version of
another pin. The backup takes its lock first, so a second backup ends 75 without having touched the executable the first runs.

`master-restore.sh <config> [<id>] --rclone-package <local .deb>`: on a bare machine the mirror is the master that is lost. The operator keeps
the package of the pin for the architecture outside that master (it is the file the mirror serves at the owned address of its row, and
its sha256 is the row's). The launcher checks the file against the rows with `openssl dgst -sha256` (macOS carries that, not `sha256sum`; a digest it cannot compute ends the
launcher with 65), sends it as base64 behind a quoted heredoc delimiter, as data, and the machine checks it again before it
installs it, with no request to the mirror or to GitHub. A restore without the option that finds the mirror lost ends 69 before it places anything,
and its refusal names this option. A file that is no package of the pin, one for another architecture or one damaged in the
session is refused. Keeping that file is a prerequisite of a recovery without the master. It solves the rclone of the restore only: the
engine and the images a full recovery needs are not provided by it (`driver.sh` names that problem).

## One backup at a time, and a backup read back

Two backups at once would leave a store stopped: the second reads the replicas of a store while the
first holds it at 0, and starts it again with 0. A plane restore empties the volume of a store the same way. So both
drivers take one lock on the machine, whichever set a backup takes, before they make or stop anything. The lock is `flock` on `/run/lock/master-backup.lock`, held for the whole run.
A second run, started from this computer or from another, stops nothing and ends at once with exit 75
(the code for "try again later"). The run that holds the lock writes its id, its process id and its act (`master`, `plane` or `plane-restore`) into the lock
file. The refusal names that run by its act, its id and its start time only while the process still has the lock file
open. A run that ended leaves its record in the file, and a lock held by hand (`flock` with a command) writes
none. In both cases the refusal says that the record is empty or names a run that is not alive, names no run,
and still ends 75.

The lock belongs to the open file, so the kernel frees it when the last process that holds the file open
ends, however it ends. A run that was killed leaves the file but no lock, and the next run starts. Nothing
needs to be cleaned up by hand. The driver's own commands (`kubectl`, `tar`, `rclone`, `gpg`) may inherit the
open file, which was not checked for the `sudo` that starts the elevated ones. If they do, the lock of a driver
that was killed lasts until the command it was running ends, which is the time it still works on a stopped
store, and the refusal names no run then, because the driver whose id the record holds is gone. A killed driver
does not start its store again; that is not changed here.

Once the archives and the manifest are on the storage box and their names are counted, the driver reads
the backup back. It copies the whole backup from the box into `/var/lib/master-backup/<id>.readback`, a
folder of root's beside the work folder, so the machine needs the backup's size in free space once more
while it runs. In that folder it checks four things: every checksum of the manifest holds, the
manifest's `STORES=` equals the number of stores this backup took, the quorum archive opens with
`BACKUP_PASSPHRASE` (the first archive of the backup does, for the set `plane`, which has no quorum), and the manifest is byte for byte the one the driver sent. The last check is what
holds the first to every archive: a checksum line that lost its form on the box is not a checksum line to
`sha256sum -c`, so the archive under it would never be read. The quorum is opened to `/dev/null`, so no
line of it is written anywhere or printed. If a check fails, the driver ends with exit 69 and names the check.

The storage box answers the `md5sum` command that rclone sends it over its shell with a failure, or never.
So the hash check of the remote is off (`disable_hashcheck = true` in the `[box]` config that
`master-backup-driver.sh`, `master-restore-driver.sh` and `plane-restore-driver.sh` write), for the carry, the read-back and the restore's
fetch alike, and rclone then compares sizes only. What proves the bytes is the manifest's sha256, which the
read-back checks for every archive.

The copy back is measured, not assumed. Before it copies, the driver asks rclone for the size of the files in the
work folder (`rclone size --json`): the bytes it expects. The copy then runs as a background job of root, and
rclone writes its log at debug level as JSON, on both of its streams, and its statistics (`--use-json-log
--log-level DEBUG --stats`, every `READBACK_POLL_SECONDS`, 5) into a file in the driver's in-memory folder, mode
600. To supervise the copy the driver reads only two numbers from the newest statistics record of that file, the
bytes received and rclone's elapsed time, as digits, and prints a line with them every `READBACK_REPORT_SECONDS` (30).

For the first `READBACK_WAIT_SECONDS` (300) the driver measures: bytes received over elapsed time. At the end of
that time it freezes the floor at the measured rate divided by `READBACK_SLOWDOWN_FACTOR` (2), the policy, and gives
the copy `ceil(expected bytes / floor)` more seconds, counted from the end of the measurement and never extended.
One line says the bytes and seconds measured, the measured rate, the floor and the seconds given. A copy that ends
within the measurement goes straight to the checks, and its bytes and duration are stated. A copy that has ended
when the driver next looks is judged by its exit status alone, whatever its allowance: 0 goes to the checks, anything
else ends the run. Only a copy that still runs is ended for its allowance. A copy that receives no
byte for `READBACK_WAIT_SECONDS`, from the start or after some progress, is ended, and so is one that gives no
statistics a number can be read from within that time or passes its allowance. A rate far below the floor that
still moves a byte at a time is ended by the allowance alone, so a very slow box is waited on for the allowance
and no longer.

Once a statistics record reports every expected byte, another rule holds. From the poll that first sees it, one
completion wait of `READBACK_FINISH_SECONDS` (300) runs on the driver's own clock, and the copy itself runs under rclone's
`--timeout` of the same length, its idle limit for one I/O. One such interval after the first complete sample is an outer policy, not proof that every retry
or close of rclone ends inside it. It is counted once: later
records, a count that repeats, grows or falls, records that stop and retries do not restart or extend it. While it
runs, the rules above do not end the copy, because a copy that has read its last byte moves no byte any more. A
copy that ends by itself inside the wait is judged by its exit status alone: 0 goes to the checks of the manifest,
anything else ends the run. A copy that still runs when the wait is over is ended with TERM, killed after
`READBACK_GRACE_SECONDS` and reaped, and the driver ends with exit 69 and the failure `read-back completion did
not finish`. It says that rclone reported every expected byte, how long the wait ran, the first complete sample (its bytes, rclone's own
elapsed time for them and their rate, taken from one statistics record) and, separately, the latest sample with its rate, and what the last
record still reports unfinished, and it names no path on the box. The line that starts the wait and the line that reports a copy that ended inside it
carry the same first complete sample and rate. A complete count, an ended copy or the end of
the wait never reaches the checks of the manifest by itself: only a copy that ended by itself with exit status 0
does.

Only when all four checks hold (the sha256 of every archive, the manifest's store count, the quorum opening to `/dev/null` and the returned
manifest equal to the one sent) the driver prints the checksum coverage: how many archives were held to their checksum, of how many the backup
must hold (one for every store and the quorum's, counted from the stores and from the manifest, not from a constant), and their names. A
checksum line that is missing, or an answer for another name, ends the run 69 with the archives kept, and no `BACKUP` line is printed.

When the records show that every expected byte was read, the driver prints a diagnosis before it ends the copy, and
also when the copy ends by itself, with 0 or not. It shows the first and the last statistics record since the count
was complete (bytes of the expected bytes, transfers and checks of their totals, errors, deletes, deleted
directories, elapsed time, the retry-error and fatal-error flags, the files listed as being transferred or checked),
when it saw the last record change, whether the transfer job and the recorded rclone process still run, how many
retry records the log holds of how many records it read, the numbered attempts and low-level retries, the version
of rclone, and the last 30 log records since the count was complete, oldest first, with the record before them as
prior context. An empty list of active files in the last record is no proof that rclone is idle, and the failure
says so. Nothing of rclone's text is printed but the
wording of its message templates, with each value rclone took from outside (an error from the box, a path, a host)
shown as `[redacted]`; numbers checked as digits; a time, a level and a source location checked by their shape; the
version of rclone; and the names of this backup's own archives and manifest. A number that is missing or malformed
reads `unavailable`, never 0. A line that is no whole JSON record is counted and not shown.

A copy is ended with TERM, then killed after `READBACK_GRACE_SECONDS` (30), and always reaped. The driver then
ends with exit 69 and says what happened, the bytes read of the bytes expected, the seconds and the average rate
(`unavailable` where no time passed, which is not a rate of 0), the exit status of the transfer where it has one,
and the work folder, which keeps the sealed archives. No other message of rclone reaches the terminal or a log: its
output stays in the file the driver reads and removes, and the errors of the upload, the listing and the restore's
fetch are dropped, the driver naming the operation and rclone's exit status instead.

The driver's clean-up ends a transfer that still runs and removes the read-back folder, as root, on every way out,
and that includes a run whose ssh session has ended: once the session is gone, the next line the driver prints
ends it, so no line after a print is where the removal can rest. The work folder is removed when the checks pass,
and the driver looks that both folders are gone before it says that nothing of the backup is left on the machine
(exit 70 where one stands). The work folder stays when a check fails or the copy back is ended, with the sealed
archives in it, as it stays after any other refusal. A run whose ssh session has ended during the read-back leaves
the work folder only. A run that is killed with KILL leaves both folders. They are root's alone and hold sealed
archives only.

## The identity is the name, and the name is a CNAME

A master's FQDN is the installation: the branch, `vault.<fqdn>`, `idp.<fqdn>`, `zot.<fqdn>`,
`tale.<fqdn>`, every slave's `global.master`, every certificate. A restore that changed it would be a
rebuild of everything that names it. So the identity is a name that can move — `master.<apex>` as a
CNAME onto `master1.<apex>` today and `master2.<apex>` tomorrow, with `*.master.<apex>` beside it
because a CNAME covers no subdomain — and the machines keep their own names and addresses. The
config states both: `FQDN` is the identity, `MACHINE_HOST` the door the launchers knock at, so a
standby is installed and kept through its own name while the identity still points at the live one.

## The order a restore stands in

1. `master-restore <config> <id>` on the bare machine. It fetches the backup, checks every checksum,
   places the platform checkout at `/srv/hostyour-cloud` with the installation's branch fetched into
   it — `driver.sh` refuses a machine that carries no checkout beside a branch that exists, because
   `deploy-branch` would cut a second one — puts `secrets/vault-<stage>.txt` back beside it, opens
   every store into a root-only staging directory, and leaves the mark `/var/lib/master-restore/pending`.
2. `install-machine <config>`, unchanged, all six programs. Right after `deploy-cluster`, `driver.sh`
   sees the mark and places the stores: each into a volume of its own under the storage root, bound
   ahead of its claim through a `PersistentVolume` with a `claimRef` — a volume's directory is named
   after the claim's uid, which exists only once the claim does, which is why the placement cannot
   come earlier and the mark is what carries it. `deploy-platform-services` then finds Vault
   initialized with its quorum in `secrets/`, unseals it with the keys in the file, and rewrites every
   mount and role for this cluster.
3. The name: `master.<apex>` and `*.master.<apex>` onto the new machine, once the run is green.

The drill is the same three steps while the first master still lives, and it is the only thing that
proves a backup: a backup that was never restored is a file.

## What it refuses

A mark already standing (a restore is staged once); a machine already carrying the platform's claims
(a restore comes before the services, and an installation that stands is not overwritten); a backup
whose checksums do not hold; a backup taken from another identity or stage; a passphrase that does
not open the quorum — each before anything is placed. Given no id, `master-restore` lists what the
storage box holds for the installation and stops.

# Abandoning an installation

```
bash lifecycle/abandon-installation.sh apps4.example.com lifecycle/config.apps4.env
```

For an installation whose machines are gone — restored to their bare points, or taken away — and
never for one that still runs: a living installation is offboarded through the Manager and taken
back with `remove-slave-from-master` and the reset. Restoring a machine takes back everything on it
and nothing beside it, and this act is for what stands beside it. What it does not touch: a
consumer's build webhook on its repository. That hook is the consumer's, written by the Manager's
onboarding under the consumer's own credential, and the next onboarding re-sets it to the new
installation's secret (hostyour-manager#198) — an installation that deleted it would reach into a
repository it holds no credential for.

Everything is derived from the install branch on origin, never typed: the cluster map of the master
and of every slave it records give the machines and their addresses (`nodeCidrs`), the consumer
registrations on the same branch and the tenant registrations on the deploy repository's books branch of the
same name give the unit names, and the map's two sender domains give the mail records. From those it
names every record the installation wrote — the platform host names of each cluster, every consumer's
`<label>.<stage apex>`, every tenant's `*.<subdomain>.<stage apex>`, and the address, SPF, DKIM and
DMARC records of each sender domain — and asks the DNS provider, with the token in the config, what
stands under each name. A record is deleted only where its content proves it the installation's: an A
or AAAA at one of the installation's addresses, a CNAME to one of its own cluster names (the wildcard
`*.<fqdn>` deploy-branch writes as an alias to `<fqdn>`, so every platform name under the installation
answers what the machine's own record answers), or an SPF that authorises those addresses and nobody
else. Everything else under a derived name is listed by name and left, because nothing on the branch
proves it — a foreign address under a unit's name, a DKIM key whose private half lived in the Vault
that is gone, a DMARC policy, an SPF merged with another sender's mechanisms. The machine's own
address record is not among the derived names: it is the machine's, and the next installation of
that name reaches the machine by it.

The order is read, guard, confirm, DNS, branches. The guard asks every address of every cluster
whether the cluster's API still answers there, on the API port and deliberately not on the ssh port:
a machine restored to its bare point still answers on 22, so that port cannot tell an installation
that is gone from a bare machine standing at the same address. A cluster that answers refuses the
whole act. Then the operator types the master's domain, and only then is anything written: the
records first, because the branch is what they are derived from, then the master's install branch,
its slaves' branches where the earlier layout cut them, and the books branch in the deploy repository, each
named. A failure in the DNS phase stops before the branches and says so; every run is safe to repeat,
because an absent record and an absent branch are not errors.

The config is read for two values, the DNS token and the deploy repository, and never run. It stays: a local
config is the record of the answers a machine was installed with, and the next machine of that name
is installed from it.

# Planning an installation domain move

```
bash lifecycle/plan-installation-domain.sh --books-fqdn master.old.example.invalid --from-domain old.example.invalid --to-domain new.example.invalid --dry-run
bash lifecycle/plan-installation-domain.sh --books-fqdn master.old.example.invalid --from-domain old.example.invalid --to-domain new.example.invalid --dry-run --fqdn master.old.example.invalid --ssh-user operator
```

It accepts `--books-fqdn HOST --from-domain DOMAIN --to-domain DOMAIN --dry-run`,
optionally `--fqdn HOST --ssh-user USER` together. It requires Node, git, yq and for machine probes
ssh. It reads every cluster map on a freshly fetched books branch; a selected machine probes both
SSH names with the existing old-name host-key trust and inventories Ingress plus IngressRoute. The
report lists proposed hostname changes and coverage; current configuration and remote state remain unchanged.
Exit 0 means a dry-run report, never cutover approval; JSON `cutoverReady=false`, full
persisted-store/client/IdP/TLS/redirect execution belongs to the coordinated Manager migration. Only
`--dry-run` is implemented. Execution and rollback require the coordinated Manager migration.

# Origin pull and zone security

```
bash lifecycle/create-origin-pull-certificate.sh lifecycle/config.master.env
bash lifecycle/apply-cloudflare-zone-security.sh lifecycle/config.master.env preview
bash lifecycle/apply-cloudflare-zone-security.sh lifecycle/config.master.env apply
```

A proxied host's origin admits a TLS connection only with the client certificate Cloudflare
presents for the zone, verified by `TLSOption` `ingress/cloudflare-origin-pull` against the CA in
`secret/<stage>/app/cloudflare-origin-pull`. `create-origin-pull-certificate.sh` makes both with
`openssl`: the CA key lives only in a temporary folder that is removed on every exit, so nothing but
the one client certificate ever chains to it. Each run writes a new pair and keeps the newest CA the
config held beside the new one, so a rotation never refuses Cloudflare in between. The order: the
script, then `regenerate-install-branch.sh` and the redeploy of the master, which carry
`CLOUDFLARE_ORIGIN_PULL_CA` into the secret store, then `apply-cloudflare-zone-security.sh apply`,
which uploads the new client certificate. The run after the next drops the old CA.

`apply-cloudflare-zone-security.sh` reads `CLOUDFLARE_ZONE_SECURITY_API_TOKEN` and the client
certificate from the config, and the zones `platformDomain` and `unitApex` from the map on the books
branch. On each zone it sets SSL mode Full (strict), raises the minimum TLS version to 1.2 where it
stands lower (1.2 and 1.3 stay), turns Email Obfuscation off, uploads the client certificate and turns
origin pull on, deploys the Cloudflare Managed Free Ruleset, and keeps two rules of its own by their `ref`:
`hostyour-next-action` blocks every request with a `Next-Action` header (403 on Free), and
`hostyour-login-rate` limits the sign-in path per address in 10-second windows. Every other rule and
setting stays as it stands. `preview` writes nothing; `apply` writes, then reads back and fails on
any difference. It stops, naming the item, on a missing permission (exit 77), a missing Managed
Free Ruleset, a full rule slot or a minimum TLS version it does not know (65), and a client
certificate Cloudflare does not present yet (75: run `preview` again, and let no route require
origin pull before it reads back active). The token and the private key reach curl on its standard
input only, and nothing prints them. The zones of a tenant's own domains are not read here: the Manager
turns Email Obfuscation off on each of them with its own token `CLOUDFLARE_ZONE_SETTINGS_API_TOKEN`.

With the minimum at 1.2 the edge refuses a browser on TLS 1.0 or 1.1. A handshake test of that
(`openssl s_client -tls1_1`) runs only on a proxied host, so the proof for a zone with none is a
`preview` after `apply` that names no `Minimum TLS version to 1.2` line.
