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
