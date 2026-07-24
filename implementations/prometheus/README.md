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

## Known issue, fixed: local-path + fsGroup

Found running against `ok-shared` (storageClass `local-path`): Prometheus
panicked on startup with `permission denied` writing to `/prometheus`.
`rancher/local-path-provisioner` backs PVs with a plain `hostPath` volume,
and kubelet does not apply automatic `fsGroup` ownership changes for
`hostPath` volumes — the chart's `runAsUser`/`fsGroup` settings are correct
but never get applied to the actual directory. Fixed with an
`initContainers` entry (`prometheus.prometheusSpec.initContainers`,
`values.yaml`) that `chown`s the volume before Prometheus starts, the same
pattern the OpenSearch chart already ships built-in. Harmless if a
different `storageClass` (Longhorn, a cloud CSI driver) is used instead —
just redundant in that case, not required. **The referenced volume name is
unverified against every kube-prometheus-stack version** — see the comment
in `values.yaml` for how to confirm/correct it.

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
