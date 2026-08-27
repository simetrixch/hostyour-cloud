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
| `install.ps1` | the operator's machine | collects, opens one session, keeps every line, fetches the records |
| `install.sh` | the operator's machine | the same, for Linux and macOS |

The two launchers are thin on purpose. **Everything is fetched by the machine itself**: the pin out
of the public platform repository, the two executables out of the public release, the catalogue out
of the private one with a read credential handed over for the length of that clone. Nothing is
carried from the operator's disk, so what stands on the machine afterwards is what the repositories
say rather than what somebody's checkout happened to hold.

## Running it

```
cp config.example.json ~/apps4.json     # NOT inside a git working tree
$EDITOR ~/apps4.json                          # 44 answers, 9 of them credentials
chmod 600 ~/apps4.json                        # Windows: icacls, and the launcher says the line

./install.sh ~/apps4.json                      # or:  pwsh ./install.ps1 ~/apps4.json
```

**No options.** An installation is a great many statements, and a command line long enough to carry
them is one nobody can read back, nobody can diff, and whose every value stands in the machine's
process listing. One file states the whole installation.

`config.example.json` is generated from what the five programs actually declare — 44 answers,
9 secret, 7 carrying a default — so it cannot drift from them silently.

## What it refuses, and why

- **A file other accounts can read.** Nine of `deploy-branch`'s answers are credentials: three
  repository *write* tokens, a DNS token, a storage password, a registry token.
- **A file standing inside a git working tree.** The mistake is made once and cannot be taken back —
  a token that reached a remote must be rotated.
- **An apostrophe in any answer.** A template slot standing inside quotes has no way to say so, and
  the cluster map becomes unparseable far from the cause
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
which lives on the machine only for the length of one `git clone` and is shredded with the envelope
on every path `driver.sh` can end on.
