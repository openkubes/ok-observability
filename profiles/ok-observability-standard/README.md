# Implementation Profile: ok-observability-standard

Reference implementation of the Observability Capability Contract v1.

- Metrics & dashboards: kube-prometheus-stack
- Logs: OpenSearch + log collector

Provider Values (per cluster): storageClass, retention (metrics/logs),
resource requests/limits, alert receiver endpoint, ingress/access config.

Constraint envelopes may substitute this profile without changing the
contract (ADR-Platform-017).
