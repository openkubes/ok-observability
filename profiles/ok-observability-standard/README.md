# Implementation Profile: ok-observability-standard

Reference implementation of the Observability Capability Contract v1,
composed as a single installable Helm chart from three independent
implementations — this is the entry point ok-cluster's `install-observability`
target (OK-79) is expected to call.

- **Metrics + Alerting** (`implementations/prometheus`): kube-prometheus-stack
  (Grafana subchart disabled — see below)
- **Dashboards** (`implementations/grafana`): standalone Grafana, wired to the
  above via datasource provisioning
- **Logs** (`implementations/opensearch`): OpenSearch + Fluent Bit

Kept as three separate charts rather than one monolith so each contract
guarantee (#1 Metrics, #2 Dashboards, #3 Logs, #4 Alerting) maps to an
independently reasoned-about, reusable unit — see each `implementations/*/README.md`.

Provider Values (per cluster): storageClass, retention (metrics/logs),
resource requests/limits, alert receiver endpoint, ingress/access config. See
the Provider Values tables in each `implementations/*/README.md`; this
chart's `values.yaml` is the single entry point that layers over them.

Constraint envelopes may substitute this profile without changing the
contract (ADR-Platform-017).

## Install

The profile commits exactly three reviewed wrapper packages under `charts/`.
Each wrapper contains its pinned upstream dependency graph. Their package
digests and the expected offline default render are bound in
`artifact-lock.json` and verified by `make verify-vendored-profile` (also part
of `make verify`). A fresh Git checkout therefore does **not** run `helm
dependency update` before rendering or installation. Updating dependencies is
an explicit maintainer operation that must regenerate and review the packages,
lock, and render evidence together.

The package graph, trust boundary, and OK-141 equivalence proof are recorded in
[SOURCE-PROVENANCE.md](SOURCE-PROVENANCE.md).

**Namespace precondition — Pod Security Admission.** `implementations/prometheus`'s
`node-exporter` and `implementations/opensearch`'s `fluent-bit` are
DaemonSets that need genuine host access (`hostNetwork`, `hostPID`,
`hostPath` mounts for `/proc`, `/sys`, `/var/log`, `hostPort`) — this is
inherent to what a node-level exporter/log collector is, not fixable via
`securityContext` tuning. If the target namespace (or the cluster's
default Pod Security Admission policy) enforces `baseline` or `restricted`,
these two DaemonSets will be rejected outright (`FailedCreate ... violates
PodSecurity`), found running against `ok-shared`. Install into a namespace
explicitly labeled to allow privileged pods:

```shell
kubectl create namespace ok-observability --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace ok-observability \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite
```

This exempts the whole namespace, which is simpler and matches common
practice for a monitoring/observability namespace — Prometheus, Grafana,
and OpenSearch themselves don't need privileged access and already run
correctly under `baseline`/`restricted`; only the two DaemonSets do.
Splitting them into a separate, more tightly-scoped namespace is possible
but adds cross-namespace Service/ServiceMonitor wiring complexity not
attempted here.

```shell
helm install ok-observability-standard profiles/ok-observability-standard \
  --namespace ok-observability \
  -f profiles/ok-observability-standard/values.yaml \
  -f alerting/alertmanager-values.yaml \
  -f <cluster-provider-values.yaml>

# Alerting rules and dashboards are plain manifests, applied separately
# (Helm chart dependencies don't cover bare CRD/ConfigMap manifests here):
kubectl -n ok-observability apply -f alerting/prometheus-rules.yaml
kubectl -n ok-observability apply -f dashboards/
```

If installing into `default` (as done in the first ok-shared test run,
before this was understood) is intentional for a quick local check, add
the same three labels to `default` instead — but a shared/default
namespace running privileged is a bigger blast radius than a dedicated one
and not recommended past a one-off test.

## Verification status

`helm dependency update`, `helm lint`, and `helm template` were run against
this chart tree on 2026-07-24: all 4 charts lint clean (only an
informational "icon is recommended" notice), template renders without
error. Three of four assumed Service names were correctly confirmed this
way: `ok-observability-prometheus`, `ok-observability-grafana`,
`ok-observability-alertmanager`. The fourth, OpenSearch, was a **false
positive** — the template grep match wasn't the real Service; see
`implementations/opensearch/README.md` "Verification status" for the real
name (`opensearch-cluster-master`), found only by actually installing
against `ok-shared`. `make verify` additionally runs a structural stand-in
(`scripts/check_charts.py`) for environments without a `helm` binary — it
would not have caught this either, since it doesn't render templates.

A subsequent live `helm install` against `ok-shared` (2026-07-24) also
surfaced: node-exporter/fluent-bit rejected by cluster-default Pod
Security Admission (see "Namespace precondition" above), a Prometheus
`permission denied` panic on `local-path` storage (see
`implementations/prometheus/README.md`), and OpenSearch's required
`OPENSEARCH_INITIAL_ADMIN_PASSWORD` (see `implementations/opensearch/README.md`).
All fixed. Contract test (`tests/contract-test.sh`) run end-to-end against
a fully-healthy install is still pending — that's the next step.
