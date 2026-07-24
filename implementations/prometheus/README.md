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

## Known issue, still open: permission denied writing to /prometheus

Found running against `ok-shared`: Prometheus panicked on startup with
`permission denied` opening `/prometheus/queries.active`. This has taken
multiple rounds of live investigation; two hypotheses are confirmed wrong
by direct re-test, one is a live-but-incomplete fix, and the real root
cause is **not yet confirmed**. Recorded here in full — including the
wrong turns — because that trail is itself the "practical viability"
finding OK-79 asked for:

1. **Disproven:** "`local-path-provisioner` doesn't support `fsGroup` at
   all." The PVC root was already correctly owned `1000:2000` and
   world-writable before any manual chown ran.
2. **Disproven (partially):** "the `subPath`-auto-created directory
   doesn't inherit `fsGroup`." True as far as it goes — fixing that
   ownership was independently necessary — but not the full story.
3. **Disproven on re-test:** "the operator-generated `prometheus`
   container's `readOnlyRootFilesystem: true` combined with the
   `subPath: prometheus-db` mount is the cause." An isolated throwaway
   container replicating both settings reproduced the identical
   `permission denied`, which looked like confirmation. But after
   overriding `readOnlyRootFilesystem` to `false` on the real container
   (via `prometheusSpec.containers`) and confirming *live*, via
   `kubectl get pod ... -o jsonpath='{.spec.containers[?(@.name=="prometheus")].securityContext}'`,
   that the override genuinely took effect (`readOnlyRootFilesystem:false`
   in the running pod spec) — **the identical panic persisted.** The
   isolated reproduction was not equivalent to the real failure; this
   hypothesis is wrong or at best incomplete.
4. **Working theory, not yet confirmed:** the panic path is
   `/prometheus/queries.active` — directly under the mount **root**, not
   under `/prometheus/prometheus-db`. The `chown` in point 2 only ever
   targeted `prometheus-db/`, never `/prometheus` itself. `values.yaml`
   now also `chown`s the mount root. This PVC has been reused across every
   `helm upgrade` since the first (pre-fix) install attempt, so a
   stale/wrongly-owned `queries.active` left over from an early crash
   cannot be ruled out either — a real fresh-PVC re-test (uninstall +
   delete PVC + reinstall, not upgrade) is the next verification step, not
   yet done.

The `readOnlyRootFilesystem: false` override is left in place (harmless,
just unproven) alongside the new mount-root chown while this is
re-verified.

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
