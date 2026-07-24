# Contract Test — Provisioning Readiness Gate

Verifies all five guarantees of the Observability Capability Contract v1.

Sequence (per ADR-Platform-018), implemented in `contract-test.sh`:

1. Deploy test workload exposing a synthetic metric (Prometheus Pushgateway)
2. Register it declaratively (ServiceMonitor)
3. Verify metric ingestion in Prometheus
4. Verify the metric is visible via a Grafana datasource query
5. Emit a synthetic log line; verify it is searchable in the log backend
6. Trigger a synthetic alert; verify it fires in Alertmanager (and, if a
   capture receiver is configured, that it is actually delivered)

A cluster is not considered fully provisioned until this test passes.

## Status

Implemented, **not yet run against a live cluster**. Authored in a
sandboxed environment with no cluster access (`kubectl` unavailable, no
KUBECONFIG) — see `AGENTS.md` / `implementations/*/README.md` for the same
caveat that applies to the Helm charts this test exercises. Practical
viability (timing, flakiness of the synthetic-alert path, behavior on
partial failure — explicitly called out in OK-79) has **not** been
validated end-to-end; that validation is the next real step once run
against ok-shared, ok1-talos, or another live cluster with the
`ok-observability-standard` profile installed.

## Known limitation: alert delivery vs. alert firing

Step 6 always verifies the synthetic alert reaches Alertmanager
(`OKObservabilitySyntheticAlert`, defined in `alerting/prometheus-rules.yaml`).
It only verifies actual **delivery** to a receiver if
`CONTRACT_TEST_RECEIVER_CAPTURE_URL` is set to a reachable capture endpoint.
By default the committed receiver (`alerting/alertmanager-values.yaml`) is a
Provider Value placeholder with no working endpoint — there is nothing real
to deliver to until a cluster configures one. Running with a capture
receiver is the strict form of this check; running without one is a
weaker, documented pass (firing only), not a silent gap.

## Usage

```shell
export KUBECONFIG=~/.kube/<target-cluster>.yaml
export GRAFANA_PASSWORD=<the cluster's Grafana admin password>
# Optional, for strict alert-delivery verification:
export CONTRACT_TEST_RECEIVER_CAPTURE_URL=http://<capture-endpoint>

make conformance
# or directly:
./tests/contract-test.sh
```

Cleans up all resources it creates (labeled
`app.kubernetes.io/managed-by=ok-observability-contract-test`) on exit,
success or failure.

## Provider Values consumed by this test

See `contracts/observability-capability-contract-v1.md` "Provider Values
(v1.1 addendum)" and the individual `implementations/*/README.md` files —
this test assumes the Service names set there
(`ok-observability-prometheus`, `ok-observability-grafana`,
`ok-observability-opensearch`, `ok-observability-alertmanager`); override
via the `*_SVC` environment variables documented at the top of
`contract-test.sh` if a cluster's naming differs.
