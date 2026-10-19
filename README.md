# hostyour-cloud

A complete multi-tenant platform for a Kubernetes cluster, as Helm charts and ArgoCD manifests. Run
it on your own machines, under your own domain, for your own customers.

Nothing in here knows who you are. Your domain is a value you set at install time; every name in the
tree is the software's own.

## What it gives you

| | |
|---|---|
| **isolation** | every consumer and every tenant gets its own namespace, its own network policy, its own quota and its own storage. What one workload can reach is a declaration, not a convention. |
| **secrets** | Vault plus External Secrets, with a per-unit path and RBAC scoped by resource name — a unit reads its own secrets and cannot name another's. |
| **builds** | a Tekton pipeline per consumer, rendered from one template, pushing to an in-cluster registry. A release is a git tag; a deployment is a pointer that moves. |
| **data** | PostgreSQL and MongoDB provisioned per unit through a `ServiceClaim` CRD, with three sizing presets and an exporter each. |
| **observability** | Prometheus, Grafana and Alloy, with alerts written against what actually breaks. |
| **mail** | a Postfix relay with DKIM, and the DNS an installation needs published. |

## The shape of it

```
clusters/      EVERYTHING A CLUSTER IS MADE OF, gathered in one place
  active/        the map of every cluster of this installation — filled only on the install
                 branch of the cluster holding the master role, empty on the trunk
  inventories/   the 18 platform applications, each a chart with an app.yaml
  units/         the four charts rendered once per unit namespace
  slaves/        the chart rendered once per slave cluster, on the master
  charts/        the library charts they are all built from
  argocd/        the ApplicationSets and projects
  bootstrap/     what is applied before ArgoCD exists
  platform/      the version pins, the order an installation's programs run in,
                 and the platform's own grammar
installation/  the per-app values and toggles of THIS installation, written per install branch
configs/       the hand-filled input of one installation, in the clear
secrets/       the same, encrypted
```

**Four directories and not eleven.** Everything that a cluster is made of stands under `clusters/`,
so the question "what does a cluster consist of" has one place to look instead of seven. What stays
outside is what is NOT a cluster: what one installation was told (`configs/`, `secrets/`) and the
per-app values it was given (`installation/`). What the installation IS stands in its own cluster
map under `clusters/active/` — one file, read as parameters by the reconciler's generators and as
values by Helm, so nothing about an installation is written down twice.

The arrangement inside `clusters/` is deliberate: every chart names its libraries relatively —
`file://../../charts/common` — so the siblings have to stand at the same depth beside each other for
those paths to resolve. Only the paths anchored at the root are free to move.

**And nothing else deploys.** No configuration and no secrets — this is structure, and it is the
same structure for everybody who clones it. What runs does so from a person's machine, never in a
cluster: `lifecycle/` carries the acts one installation's life is made of — installing the first
master, which brings the installation into being; releasing the platform tree and pinning an
installation to that release; regenerating an install branch onto the pin it carries; and migrating
the facts which are born on install branches and reachable neither by a merge nor by a regeneration.
What belongs to ONE installation comes from outside: that company's own repository, carrying its
configuration in the clear and its secrets encrypted, handed to the deployer along with the key that
opens them.

Nothing on the trunk names one installation. A cluster's own settings and what it knows about
itself stand on its install branch, never here — which is what lets a second installation take the
same tree and be a different company.

## What deploys it

`ansiwise-core` — a framework that runs a declared program of steps against a machine, with three
modes that gate each other: a test that measures, a dry run that cannot mutate, and a real run that
refuses without a green dry run for the same input.

## What onboards into it

`hostyour-manager` — it creates consumers and tenants: the namespace, the Vault path, the databases,
the build pipeline and the registrations, in an order that can be undone if a step fails.

## Where the first images come from

Every unit of the platform is built inside the installation that runs it, by a pipeline rendered
from a registration that `hostyour-manager` writes. Its own three images cannot come from there: on
a machine where nothing is installed yet, there is no manager to write that registration.

They come from the owner's registry under the owner's name: `simetrixch/manager`,
`simetrixch/gate-runner` and `simetrixch/dbtools` at `zot.master.digitacloud.app`
(`global.buildRegistry` in `clusters/platform/values-common.yaml`). The owner's master builds them
with its own release pipeline, because `hostyour-manager` is a unit there (`global.buildRegistryUnit`),
and the registry answers an anonymous pull under `simetrixch/**` and nowhere else. So a fresh
installation fetches them with no credential and no request to GitHub. The owner's master itself,
rebuilt from nothing, gets them back with the backup of its registry (`lifecycle/master-restore-driver.sh`).

## Checks

`bash scripts/check.sh` runs local chart validation and
credential scanning. It names the suites that did not run locally.

The master's ci is the Tekton pipeline `hostyour-cloud-ci`
(`clusters/inventories/consumer-build/templates/pipeline-ci.yaml`). It runs those checks and
`bash scripts/test.sh` on every push of the default branch that does more than move release pins: the check
step installs the tools `ci-tools.json` names, then runs `scripts/check.sh` and `scripts/test.sh`.
The test entry point runs its suites `TEST_JOBS` at a time (4 unless set), after it has built the chart
dependencies they render, and prints a failed suite in full. Run tests only on a remote runner.

A run is one task, `ci`, in one pod, whose steps run one after the other and share an `emptyDir` of
`ciScratch.size`; the run carries no workspace. A commit whose head already carries a green `tekton/ci` is not checked
again: the step `earlier-green` ends the run with the result `earlier-run`, and the status keeps naming the run that did
the check. The claim `ci-cache` of the unit (`ciCache.size`, evicted by last access when the check step ends) keeps the
tool archives, the Go and pnpm caches and the helm cache between runs.

Read its runs on the master as the PipelineRuns `hostyour-cloud-ci-*` in the namespace `hostyour-cloud-build`,
or as the commit status `tekton/ci` on the commit
(`clusters/inventories/consumer-build/files/ci-commit-status.sh`). A push of the default branch or of a
`ci/` branch of a public repository starts a run through the Trigger `github-ci-push`
(`clusters/inventories/image-builder/templates/triggers/github-ci-push.yaml`); a push of a private repository
starts none and sets no `tekton/ci` status, because the trigger reads `repository.visibility` of the push.

An issue branch is judged by the push gate on the machine and starts no ci run on the master.
To run the master's ci on another commit, for example a planted defect that must show the check red,
push it to a branch whose name starts with `ci/`:

```bash
git push origin HEAD:ci/issue-<n>-planted-1
```

Delete that branch once its run has finished. A run whose `ci/` branch is deleted before it finishes is cancelled by
the ci run keeper within a minute (annotation `image-builder.io/branch-deleted` on the run), and every run ends
at the bound set in `ciPush.timeouts` of `clusters/inventories/image-builder/values-common.yaml`.

## License

**Elastic License 2.0.** Run it, change it, deploy it — for yourself, your company and your
customers' workloads. What needs a separate license from simplidigita AI GmbH is offering it to third
parties as a hosted or managed service.

See [LICENSE.md](LICENSE.md).
