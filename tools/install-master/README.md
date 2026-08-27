# install-master

A first master, installed from zero, from an operator's own machine — Windows, Linux or macOS.

## What this is, and what it is not

It is a **driver**. It runs no step and decides nothing an answer should decide. It reads the order
out of [`clusters/platform/install-order.yaml`](../../clusters/platform/install-order.yaml)'s own
sequence, puts the two things a program cannot put there itself — the engine and the catalogue — and
then invokes the five programs, each of them three times. That file states the division in its own
words:

> THIS FILE STATES THE ORDER. IT DOES NOT RUN IT. A driver reads the sequence and invokes the
> programs itself.

`ansiwise-client` is the other driver, and the one to prefer when a person is at a screen: it shows
each step, asks before it acts, and can stop. This exists for the operator who wants one command, one
transcript, and every line of it kept.

## The three files

| file | where it runs | what it does |
|---|---|---|
| `driver.sh` | **on the machine** | the whole installation: preconditions, engine, catalogue, the five programs |
| `install.ps1` | the operator's machine | checks the config, opens one session, keeps every line, fetches the records |
| `install.sh` | the operator's machine | the same, for Linux and macOS |

The two launchers are thin on purpose. **Everything is fetched by the machine itself**: the pin out
of the public platform repository, the two executables out of the public release, the catalogue out
of the private one with a read credential handed over for the length of that clone. Nothing is
carried from the operator's disk, so what stands on the machine afterwards is what the repositories
say rather than what somebody's checkout happened to hold.

## Running it

```
cp config.example.env ~/apps4.env     # NOT inside a git working tree
$EDITOR ~/apps4.env                   # 34 values, 10 of them credentials
chmod 600 ~/apps4.env                 # Windows: icacls, and the launcher says the line

./install.sh ~/apps4.env              # or:  pwsh ./install.ps1 ~/apps4.env
```

**No options.** An installation is a great many statements, and a command line long enough to carry
them is one nobody can read back, nobody can diff, and whose every value stands in the machine's
process listing. One file states the whole installation.

**`NAME='value'` and not JSON**, for the reason this organisation's board tooling is the same shape:
a shell reads it with one `.` and needs no parser, no `jq` and no Python. JSON would cost every
operator a dependency, and it cannot carry the one thing that file needs most — a sentence saying
what a value is.

`config.example.env` is generated from what the five programs actually declare, so it cannot drift
from them silently.

## What it refuses, and why

- **A file other accounts can read.** Ten of the thirty-four values are credentials: the elevation
  password of the machine, four repository *write* tokens, two repository read tokens, a DNS token,
  a storage password and a registry token.
- **A file standing inside a git working tree.** The mistake is made once and cannot be taken back —
  a token that reached a remote must be rotated.
- **Any line that is not a comment or `NAME='value'`.** The config is READ BY THE SHELL on the
  machine, so a line that is not an assignment is a command that would run there with the operator's
  own rights. All three files apply the same test, and the launcher quotes the offending line with
  its number.
- **An apostrophe in any value.** That test refuses it as a side effect, and it would break the run
  in any case: a template slot standing inside quotes has no way to say so, and the cluster map
  becomes unparseable far from the cause
  ([`ansiwise-plugins#161`](https://github.com/simetrixch/ansiwise-plugins/issues/161)).

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

Two reach the machine and neither ever stands in an argument list: the elevation password, which
raises every command that has to run as root, and a **read** credential for the private catalogue,
which lives on the machine only for the length of one `git clone` and is shredded with the config on
every path `driver.sh` can end on.
