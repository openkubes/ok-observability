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

Implemented and run against two real clusters (`ok-infra`, `ok-shared`) —
**neither had the profile installed**, which is exactly what surfaced the
false-positive bug documented below and led to the current, hardened
version. Still not validated end-to-end against a cluster where
`ok-observability-standard` actually IS installed — that remains the next
real step, and is expected to reveal further practical-viability issues
(timing, flakiness of the synthetic-alert path) per OK-79.

## Known issue, fixed (found running against real clusters)

The first version of this script produced **false PASS results** when the
target services didn't exist at all. Root cause, confirmed empirically:
`curl -sf ... | jq -e '<filter>'` returns exit **0** when curl fails and jq
receives *empty* input — `jq -e` treats "no document at all" as success, not
as an error. Combined with `pipefail` not propagating into a nested
`bash -c "..."` subshell, a silently-failed `kubectl port-forward` (because
the Service didn't exist) produced an instant, contentless "ok" instead of
a timeout or a clear error.

Found by running `make conformance` against `ok-infra` and `ok-shared`,
neither of which had the profile installed — every async check reported
"ok" within seconds despite there being nothing to verify. Fixed by:
adding `set -o pipefail;` inside every `curl | jq` subshell, adding an
explicit Service-existence precondition per component (fails fast with a
named diagnostic instead of a 120s timeout), and verifying each
port-forward is actually serving traffic (health-endpoint probe) before
any check runs against it. This is exactly the "behavior on partial
failure" OK-79 asks to have proven — recorded here rather than only in a
commit message.

## Known issue, fixed (2): cleanup leaked resources on CRD-less clusters

The trap-based cleanup issued one `kubectl delete deploy,svc,job,pod,configmap,servicemonitor ...`
call. If any single kind in that comma-joined list isn't registered on the
cluster (exactly the `servicemonitor` case above, no CRD), kubectl aborts
the **entire** multi-kind delete before deleting anything —
`--ignore-not-found` only suppresses "not found" for a missing *named*
object, not a missing *resource type*. Result: the synthetic Pushgateway
Deployment/Service/Pod from the very first (pre-fix) run against
`ok-shared` was left running for the lifetime of the cluster, found via
`kubectl get pods -A`. Fixed by issuing one delete call per kind, so a
missing type only affects that one call.

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
# OpenSearch's security plugin serves HTTPS + Basic Auth, so step 5 needs
# the admin credentials too (must match OPENSEARCH_INITIAL_ADMIN_PASSWORD).
# Without OPENSEARCH_PASSWORD, step 5 fails with an actionable message
# rather than silently passing:
export OPENSEARCH_PASSWORD=<the cluster's OpenSearch admin password>
# Default namespace matches profiles/ok-observability-standard/README.md's
# recommended install namespace; override if you installed elsewhere:
export CONTRACT_TEST_NAMESPACE=ok-observability
# Optional, for strict alert-delivery verification:
export CONTRACT_TEST_RECEIVER_CAPTURE_URL=http://<capture-endpoint>

make conformance
# or directly:
./tests/contract-test.sh
```

Cleans up all resources it creates (labeled
`app.kubernetes.io/managed-by=ok-observability-contract-test`) on exit,
success or failure.

The script derives a deterministic, checksum-suffixed `run-id` label and
resource names from `CONTRACT_TEST_RUN_ID`. This keeps Service names and label
values within Kubernetes' 63-character boundary even when the supplied run ID
is long; the unmodified run ID remains the human-facing test identity.

## Provider Values consumed by this test

See `contracts/observability-capability-contract-v1.md` "Provider Values
(v1.1 addendum)" and the individual `implementations/*/README.md` files —
this test assumes the Service names set there
(`ok-observability-prometheus`, `ok-observability-grafana`,
`ok-observability-opensearch`, `ok-observability-alertmanager`); override
via the `*_SVC` environment variables documented at the top of
`contract-test.sh` if a cluster's naming differs.
