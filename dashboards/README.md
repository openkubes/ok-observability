# dashboards/

Platform Grafana dashboards, delivered as ConfigMaps labeled
`grafana_dashboard: "1"`. `implementations/grafana`'s sidecar
(`sidecar.dashboards`, `searchNamespace: ALL`) discovers them cluster-wide —
no dashboard provisioning changes needed when adding a new one here.

## Adding a dashboard

1. Export the dashboard JSON from Grafana (Dashboard settings → JSON Model),
   or author it directly.
2. Wrap it in a ConfigMap: one JSON file per `data` key, `metadata.labels.grafana_dashboard: "1"`.
3. Name the ConfigMap `ok-observability-dashboard-<short-name>`.

## Contents

| File | Dashboard | Guarantee exercised |
|---|---|---|
| `platform-overview-configmap.yaml` | Platform Overview — node CPU, pod restarts | #1 Metrics, #2 Dashboards |

This is a minimal starting dashboard, not a complete catalog — it exists so
the contract test (readiness gate, OK-79) has a real datasource query to
verify, per its verification sequence ("verify the metric is visible via
Grafana datasource query").
