# Contract Test — Provisioning Readiness Gate

Verifies all five guarantees of the Observability Capability Contract v1.

Sequence (per ADR-Platform-018):

1. Deploy test workload exposing a synthetic metric
2. Register it declaratively (ServiceMonitor)
3. Verify metric ingestion in Prometheus
4. Verify the metric is visible via Grafana datasource query
5. Emit a synthetic log line; verify it is searchable in the log backend
6. Trigger a synthetic alert; verify delivery at the configured receiver

A cluster is not considered fully provisioned until this test passes.

Status: to be implemented (see ok-cluster integration ticket).
