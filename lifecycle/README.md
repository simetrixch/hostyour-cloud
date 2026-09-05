# lifecycle

The life of one installation: the act that brings it into being, every release put on it afterwards,
and the registration one installation holds for another taken off again. Everything here runs from
an operator's own machine — Windows, Linux or macOS — and nothing here runs in a cluster.

**The subject is an installation, not a delivery.** A first install delivers nothing; it creates. The
acts below share a subject rather than a purpose, which is why they stand in one folder.

## The acts

| act | what it does |
|---|---|
| `install-machine.sh` / `.ps1` | installs a first master from zero: a machine, a branch, a cluster and the platform services on it |
| `release-platform.sh` / `.ps1` | cuts a release of the platform tree and pins ONE installation to it |
| `regenerate-install-branch.sh` / `.ps1` | brings an installation onto the release its own map is pinned to |
| `remove-slave-from-master.sh` / `.ps1` | takes ONE slave's registration off the master it stands on |
| `status.sh` / `.ps1` | answers which release each installation stands on, and what the trunk carries since |

Every one of them is written twice, and the two spellings are held to doing the same in the same
order and printing the same bytes. `test.sh` is what measures that, against fixtures it builds in a
temporary directory.

**Three files here are not a person's entry point.** `driver.sh` is the installation itself,
`regenerate-driver.sh` is the regeneration itself and `remove-slave-driver.sh` is the removal itself:
all three run ON THE MACHINE, and the launcher beside them carries them over the session it opens.
None of them is started by hand.

## The order the acts stand in

A release is TWO acts and they are separate on purpose. `release-platform` puts the tag on the remote
and writes `release: <tag>` into `clusters/active/<fqdn>.yaml` on the installation's own branch —
and stops. The installation still stands on the state before it. `regenerate-install-branch` is what
brings the branch to the pin: it reads the ref off that line rather than being told it again, so the
pin and the regeneration are one statement instead of two that can disagree. Between the two acts
somebody can read what the pin now says and stop.

# Installing a first master

A first master, installed from zero, from an operator's own machine.

## What this is, and what it is not

It is a **driver**. It runs no step and decides nothing an answer should decide: it puts the two
things a program cannot put there itself — the engine and the catalogue — and then invokes the five
programs that make a master, each of them three times.
[`clusters/platform/install-order.yaml`](../clusters/platform/install-order.yaml) states that
division in its own words:

> THIS FILE STATES THE ORDER. IT DOES NOT RUN IT. A driver reads the sequence and invokes the
> programs itself.

**`driver.sh` carries its own copy of that sequence and does not read the file.** So does the
Manager, in TypeScript. Three carriers of one fact, and the one written to be the answer is the one
nothing reads; both `driver.sh` and `install-order.yaml` say so in their own headers rather than
leaving the drift to be discovered.

`ansiwise-client` is the other driver, and the one to prefer when a person is at a screen: it shows
each step, asks before it acts, and can stop. This exists for the operator who wants one command, one
transcript, and every line of it kept.

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
| `driver.sh` | **on the machine** | the whole installation: preconditions, engine, catalogue, the five programs |
| `install-machine.ps1` | the operator's machine | checks the config, opens one session, keeps every line, fetches the records |
| `install-machine.sh` | the operator's machine | the same, for Linux and macOS |

`install-machine.ps1` is for **Windows** and `install-machine.sh` for **Linux and macOS**. They are
held to answering identically, and the one real difference is how each asks whether the config is
protected: Windows says that with an access list and reads it with `icacls`, Linux and macOS say it
with a mode and read it with `stat`.

The two launchers are thin on purpose. **Everything is fetched by the machine itself, and all three
are public**: the pin out of the platform repository, the two executables out of the release, the
catalogue out of `hostyour-deploy`, the repository the deployment programs stand in. Nothing is
carried from the operator's disk, so what stands on the machine afterwards is what the repositories
say rather than what somebody's checkout happened to hold.

## Running it

```
cp config.example.env ~/apps4.env     # NOT inside a git working tree
$EDITOR ~/apps4.env                   # one line per value; the credentials are marked
chmod 600 ~/apps4.env                 # Windows: icacls, and the launcher says the line

./install-machine.sh ~/apps4.env      # or:  pwsh ./install-machine.ps1 ~/apps4.env
```

**No options.** An installation is a great many statements, and a command line long enough to carry
them is one nobody can read back, nobody can diff, and whose every value stands in the machine's
process listing. One file states the whole installation.

**`NAME='value'` and not JSON**, for the reason this organisation's board tooling is the same shape:
a shell reads it with one `.` and needs no parser, no `jq` and no Python. JSON would cost every
operator a dependency, and it cannot carry the one thing that file needs most — a sentence saying
what a value is.

`config.example.env` is generated from what the five programs actually declare, so it cannot drift
from them silently. `regenerate-install-branch` reads the same file, in the same grammar, for the
same reason: what an installation is, is stated once.

## Which door it opens

The two cases this has to serve are opposites, so the launcher **asks the machine first** and needs
no flag from you:

- **A machine this platform installed** carries the operator key, and `disable-password-login` has
  shut its password door. The key is tried first, so this is the normal path and nothing is asked.
- **A machine at its birth carries no key at all.** `deploy-host`'s `install_authorized_key` row is
  what puts it there, and that row is one of the five programs this is about to run — so the very
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
  own rights. All three files apply the same test, and the launcher quotes the offending line with
  its number.
- **An apostrophe in any value.** That test refuses it as a side effect, and it would break the run
  in any case: a template slot standing inside quotes has no way to say so, and the cluster map
  becomes unparseable far from the cause (`ansiwise-plugins#161`).
- **A carriage return anywhere in the config.** Notepad writes CRLF, and a `bash` on Linux reads
  that CR as part of the value — so the FQDN a certificate is issued for would end in a control
  character and nothing downstream would say why. Both launchers strip it on the way over and
  `driver.sh` refuses it on arrival.

## The one thing it does that no program does

It installs `git`, `curl` and `python3` when they are missing. `deploy-host`'s `install_packages` row
installs them too — and the catalogue those programs are *read from* cannot be cloned without git, so
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
the catalogue needs none — the repository the deployment programs stand in is public, so the clone
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

The second opens one session to the machine and runs `regenerate-branch` there, in the three modes
that gate one another. It takes the domain and nothing else — the ref comes off the pin, and the
answers come from the same `NAME='value'` config an installation was installed with. It refuses,
before it touches the machine, where the branch does not exist, where the map carries no `release:`
line, and where the tag that line names is not on the remote; every one of those refusals says that
nothing has been changed, because at every one of them nothing has.

The third only answers, and writes nothing at all.
