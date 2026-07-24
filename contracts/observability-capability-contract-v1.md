# Observability Capability Contract v1

**Source of truth:** ADR-Platform-018 (openkubes/openkubes, commit 28f88e5)
**Status:** Accepted 2026-07-13

## Guarantees

An OpenKubes cluster is considered successfully provisioned only after the
following guarantees have been verified:

1. Metrics: workloads can declaratively register for metrics collection
   (ServiceMonitor/PodMonitor semantics); platform components are scraped
   by default.
2. Dashboards: a Grafana instance is reachable inside the cluster,
   pre-provisioned with platform dashboards.
3. Logs: platform and workload container logs are collected according to
   the cluster's declared logging policy and are searchable through the
   cluster-local log backend. Default policy: all container logs;
   exclusions and retention are Provider Values.
4. Alerting: alerts can be delivered to a cluster-defined receiver endpoint.
5. Autonomy: the stack functions without connectivity to any other cluster.

## Not covered by v1

- Cross-cluster federation / long-term aggregation
- Tracing and profiling
- Native OTLP ingestion (designated future extension path via
  Collector-based pipeline)

## Verification

See tests/ — the contract test is the provisioning readiness gate.

## Provider Values (v1.1 addendum, 2026-07-24)

Formalizing what was previously only implied in the README chain diagram —
no change to the five guarantees above, no re-review required:

- **storageClass** — via the ok-storage contract; applies to Prometheus,
  Alertmanager, Grafana, and OpenSearch persistent volumes
- **retention** — metrics (Prometheus) and logs (OpenSearch/ILM) retention
  windows
- **resources** — requests/limits for all stack components
- **alert receiver** — the Alertmanager receiver endpoint alerts are
  delivered to (guarantee #4)
- **ingress/access** — whether/how Grafana and other UIs are exposed;
  external exposure requires a separate ADR-010 decision, not implied by
  setting this value

Provider Values are supplied per cluster and never committed to this repo
(see `AGENTS.md`). This addendum surfaced while authoring the
`ok-observability-standard` profile content for OK-79.
