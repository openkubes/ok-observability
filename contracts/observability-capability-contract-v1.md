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
