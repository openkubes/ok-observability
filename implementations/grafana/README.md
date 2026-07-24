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

`helm lint` and `helm template` were run against `profiles/ok-observability-standard`
(which depends on this chart) on 2026-07-24 — clean lint (only an informational
"icon is recommended" notice), template renders without error, and the
Prometheus datasource URL assumption was confirmed against the rendered
Service name (`ok-observability-prometheus`). Not yet verified: an actual
`helm install` on a live cluster (next step, see `profiles/ok-observability-standard/README.md`).

## Usage

```shell
helm dependency update implementations/grafana
helm template implementations/grafana \
  -f implementations/grafana/values.yaml \
  -f <cluster-provider-values.yaml>
```

Consumed as a dependency of `profiles/ok-observability-standard`.
