# implementations/grafana

Reference implementation of ADR-Platform-018 guarantee **#2 Dashboards**, via
the standalone [grafana/grafana](https://github.com/grafana/helm-charts/tree/main/charts/grafana)
chart (pinned in `Chart.yaml`) — deliberately independent of
kube-prometheus-stack's bundled Grafana subchart, which is disabled in
`implementations/prometheus`.

Same pattern as the `central-grafana` precedent used for `ok-shared`
(`docs/ok-shared-onboarding-guideline.md` in the platform repo) — a
standalone Grafana release is easier to reason about, test, and reuse than a
subchart wired implicitly through kube-prometheus-stack's values.

## What this owns

- Grafana deployment, persistence
- Datasource provisioning pointing at `implementations/prometheus`
- Dashboard sidecar, discovering `dashboards/` ConfigMaps cluster-wide

## Provider Values

| Value | Where | Default here |
|---|---|---|
| `storageClassName` | `persistence.storageClassName` | `""` (cluster default) |
| `adminPassword` | `adminPassword` | `""` — must be set at install time, never committed |
| ingress/access | `ingress.enabled` | `false`; requires an ADR-010 decision to expose externally |

## Verification status

`helm lint` / `helm template` could not be executed in the environment this
chart was authored in — no `helm` binary was installable (network egress to
`get.helm.sh` and `api.github.com` was blocked; only a curated allowlist,
e.g. pypi, was reachable). `make verify` runs a structural equivalent
(`scripts/check_charts.py`: valid YAML, required `Chart.yaml` fields,
dependency entries resolvable) as a stand-in — **not** a substitute for a
real `helm template` render. Run `helm dependency update && helm lint && helm
template` here before merging, and correct the Prometheus datasource URL
above if the rendered Service name differs from the assumption noted in
`values.yaml`.

## Usage

```shell
helm dependency update implementations/grafana
helm template implementations/grafana \
  -f implementations/grafana/values.yaml \
  -f <cluster-provider-values.yaml>
```

Consumed as a dependency of `profiles/ok-observability-standard`.
