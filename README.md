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
apps/          the 18 platform applications, each a chart with an app.yaml
units/         the four charts rendered once per unit namespace
slaves/        the chart rendered once per slave cluster, on the master
charts/        the library charts they are built from
argocd/        the ApplicationSets and projects
bootstrap/     what is applied before ArgoCD exists
cluster/       what ONE cluster is: its application toggles and its profile
clusters/      an installation's cluster maps
platform/      the version pins and the platform's own grammar
```

**And nothing else.** No configuration, no secrets, no executable and no code that runs — this is
structure, and it is the same structure for everybody who clones it. What belongs to ONE
installation comes from outside: that company's own repository, carrying its configuration in the
clear and its secrets encrypted, handed to the deployer along with the key that opens them.

`branch-classes.yaml` states what every path here IS — **product** (byte-identical in every
installation), **install** (one cluster's own settings) or **books** (what one installation knows
about itself) — and why. That distinction is what keeps an installation's own state off the trunk,
so a second installation can take the same tree and be a different company.

## What deploys it

[ansiwise](https://github.com/simetrixch/ansiwise-api) — a framework that runs a declared program of
steps against a machine, with three modes that gate each other: a test that measures, a dry run that
cannot mutate, and a real run that refuses without a green dry run for the same input.

## What onboards into it

`hostyour-manager` — it creates consumers and tenants: the namespace, the Vault path, the databases,
the build pipeline and the registrations, in an order that can be undone if a step fails.

## License

**Elastic License 2.0.** Run it, change it, deploy it — for yourself, your company and your
customers' workloads. What needs a separate license from Simetrix GmbH is offering it to third
parties as a hosted or managed service.

See [LICENSE.md](LICENSE.md).
