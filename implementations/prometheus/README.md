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

## Known issue, fixed: permission denied writing to /prometheus

Found running against `ok-shared`: Prometheus panicked on startup with
`permission denied` writing to `/prometheus`. This took three rounds of
live investigation to pin down correctly — both intermediate hypotheses
are recorded here because they were reasonable, evidence-based, and wrong,
and the process of ruling them out is exactly the "practical viability"
finding OK-79 asked for:

1. **Disproven:** "`local-path-provisioner` doesn't support `fsGroup` at
   all." The PVC root was already correctly owned `1000:2000` and
   world-writable before any manual chown ran — ownership was never wrong
   at the mount root.
2. **Disproven (partially):** "the `subPath`-auto-created directory
   doesn't inherit `fsGroup`." True as far as it goes — Kubernetes does
   auto-create a missing `subPath` directory without applying `fsGroup`
   ownership to it, and fixing that ownership *was* necessary — but a
   write test as the exact target UID/GID still failed afterward when
   also using `readOnlyRootFilesystem: true`, proving ownership alone
   wasn't the full story.
3. **Confirmed root cause:** the operator-generated "prometheus" container
   sets `readOnlyRootFilesystem: true` **and** mounts the data volume via
   `subPath: prometheus-db`. That combination made the subPath mount
   behave as read-only on this cluster's container runtime — reproduced
   directly by replicating both settings in a throwaway container and
   getting the identical `permission denied`.

Fix has two parts, both in `values.yaml`:
- `prometheus.prometheusSpec.initContainers`: creates and `chown`s
  `/prometheus/prometheus-db` (still needed on its own — see point 2)
- `prometheus.prometheusSpec.containers`: overrides the generated
  "prometheus" container's `readOnlyRootFilesystem` to `false`, using
  Prometheus Operator's supported mechanism for patching
  operator-generated containers by name

Harmless if a different `storageClass` is used — the `chown` step is
redundant but not required there; the `readOnlyRootFilesystem` override is
needed regardless of storage class, since the cause is the subPath
mount/runtime interaction, not the storage backend itself.

**The referenced volume name and subPath are verified against the pinned
kube-prometheus-stack version as of 2026-07-24 (live `kubectl` inspection),
not guaranteed across version bumps** — see the comment in `values.yaml`
for how to re-confirm.

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
