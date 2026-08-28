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

The arrangement inside `clusters/` is deliberately the one it always had, because every chart names
its libraries relatively — `file://../../charts/common`, nineteen times over. Moving the siblings
together left all of them true, and only the paths anchored at the root had to change.

**And nothing else.** No configuration, no secrets, no executable and no code that runs — this is
structure, and it is the same structure for everybody who clones it. What belongs to ONE
installation comes from outside: that company's own repository, carrying its configuration in the
clear and its secrets encrypted, handed to the deployer along with the key that opens them.

Nothing on the trunk names one installation. A cluster's own settings and what it knows about
itself stand on its install branch, never here — which is what lets a second installation take the
same tree and be a different company.

## What deploys it

[ansiwise](https://github.com/simetrixch/ansiwise-core) — a framework that runs a declared program of
steps against a machine, with three modes that gate each other: a test that measures, a dry run that
cannot mutate, and a real run that refuses without a green dry run for the same input.

## What onboards into it

`hostyour-manager` — it creates consumers and tenants: the namespace, the Vault path, the databases,
the build pipeline and the registrations, in an order that can be undone if a step fails.

## Where the first images come from

Every unit of the platform is built inside the installation that runs it, by a pipeline rendered
from a registration that `hostyour-manager` writes. Its own three images cannot come from there: on
a machine where nothing is installed yet, there is no manager to write that registration.

They come from `ghcr.io/simetrixch/manager`, `.../gate-runner` and `.../dbtools`, pushed by the
`release-images` workflow of `hostyour-manager` when a release tag is pushed, under the same
`<release-tag>-<sha7>` image tag the in-cluster pipeline composes. The registry in
`clusters/inventories/registry/values-common.yaml` fetches them on the first pull and stores them under their flat
build name, so nothing downstream can tell where a given tag came from — and from the installation's
own first build onwards it never asks again, because a tag it already holds is a local hit.

**Those three packages have to be public, and nothing makes them so.** GHCR sets visibility per
package, a package pushed for the first time is private, and no workflow token changes that — a
person turns each of the three public once. Until that is done, a fresh installation's pull is
refused, and what an operator sees is an `ImagePullBackOff` naming no cause.

## License

**Elastic License 2.0.** Run it, change it, deploy it — for yourself, your company and your
customers' workloads. What needs a separate license from Simetrix GmbH is offering it to third
parties as a hosted or managed service.

See [LICENSE.md](LICENSE.md).
