# implementations/prometheus

Reference implementation of ADR-Platform-018 guarantees **#1 Metrics** and
**#4 Alerting**, via [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
(chart pinned in `Chart.yaml`).

## What this owns

- Prometheus + kube-state-metrics + node-exporter (metrics collection and
  declarative registration via ServiceMonitor/PodMonitor)
- Alertmanager (delivery mechanism; routing/receivers are layered in from
  `alerting/alertmanager-values.yaml`, not set here)

## What this deliberately does not own

- Grafana / dashboards — guarantee #2, served by `implementations/grafana` as
  an independent release. The chart's bundled Grafana subchart is disabled
  (`grafana.enabled: false`) to avoid two unconfigured Grafana instances.
- Alert routing/receivers — a Provider Value, composed from `alerting/` at
  install time to keep alerting concerns out of metrics values.
- Logs — guarantee #3, served by `implementations/opensearch`.

## Provider Values

| Value | Where | Default here |
|---|---|---|
| `storageClassName` | Prometheus + Alertmanager PVCs | `""` (cluster default) |
| retention | `prometheus.prometheusSpec.retention` | `15d` |
| resources | `prometheus.prometheusSpec.resources` / `alertmanager.alertmanagerSpec.resources` | dev-sized defaults |
| alert receiver | `alerting/alertmanager-values.yaml` | placeholder receiver, must be overridden |

## Known issue, fixed: subPath directory doesn't inherit fsGroup

Found running against `ok-shared`: Prometheus panicked on startup with
`permission denied` writing to `/prometheus`. First hypothesis — that
`local-path-provisioner`'s PVs don't support `fsGroup` at all — was
**disproven** by the fix's own diagnostic output: the PVC root was already
correctly owned `1000:2000` and world-writable before any manual chown ran.

Real cause: the "prometheus" container mounts the volume with
`subPath: prometheus-db` (confirmed via `kubectl get pod ... -o json | jq
'.spec.containers[] | select(.name=="prometheus") | .volumeMounts'`).
Kubernetes auto-creates a missing subPath directory at pod start but does
**not** apply `fsGroup`-based ownership to that auto-created directory —
distinct from, and easy to confuse with, ownership of the PVC/mount root
itself. Fixed with an `initContainers` entry
(`prometheus.prometheusSpec.initContainers`, `values.yaml`) that creates
and `chown`s `/prometheus/prometheus-db` specifically, not just
`/prometheus`. Harmless if a different `storageClass` is used instead —
redundant in that case, not required. **The referenced volume name and
subPath are verified against the pinned kube-prometheus-stack version as
of 2026-07-24 (live `kubectl` inspection), not guaranteed across version
bumps** — see the comment in `values.yaml` for how to re-confirm.

## Usage

```shell
helm dependency update implementations/prometheus
helm template implementations/prometheus \
  -f implementations/prometheus/values.yaml \
  -f alerting/alertmanager-values.yaml \
  -f <cluster-provider-values.yaml>
```

In practice this chart is consumed as a dependency of
`profiles/ok-observability-standard` — see that chart for the single
installable entry point.
