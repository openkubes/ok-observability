#!/usr/bin/env bash
# Contract Test — Provisioning Readiness Gate (ADR-Platform-018)
#
# Verifies the five Observability Capability Contract v1 guarantees against
# a live cluster where the ok-observability-standard profile is installed.
# See tests/README.md for the verification sequence this implements.
#
# Requires: kubectl (pointed at the target cluster via KUBECONFIG), curl, jq.
# Provider Values for this test are environment variables — see the
# defaults below. None are secrets; a real alert-receiver endpoint is a
# separate concern (see step 6 and CONTRACT_TEST_RECEIVER_CAPTURE_URL).
#
# Exit non-zero on ANY failed guarantee. Cleans up its own resources on
# exit regardless of outcome (OK-79: "behavior on partial failure").
#
# IMPORTANT correctness note (found the hard way, see tests/README.md
# "Known issue, fixed"): `curl -sf ... | jq -e '<filter>'` WITHOUT
# `pipefail` reports success (exit 0) even when curl fails and jq sees
# EMPTY input — jq -e treats "no document at all" as a non-error. Every
# curl|jq check below explicitly sets `pipefail` inside its own `bash -c`
# subshell (the outer `set -o pipefail` does NOT propagate into a nested
# `bash -c "..."` invocation). Do not remove these without understanding
# why they're there — it silently turns "the service doesn't exist" into
# a false PASS.
set -uo pipefail

# --- Configuration (Provider Values for this test run) ----------------------
NAMESPACE="${CONTRACT_TEST_NAMESPACE:-ok-observability}"
RUN_ID="${CONTRACT_TEST_RUN_ID:-$(date +%s)-$$}"
TIMEOUT="${CONTRACT_TEST_TIMEOUT:-120}"       # seconds to wait per async check
POLL_INTERVAL="${CONTRACT_TEST_POLL_INTERVAL:-5}"

PROMETHEUS_URL="${PROMETHEUS_URL:-}"           # empty => port-forward is used
GRAFANA_URL="${GRAFANA_URL:-}"
OPENSEARCH_URL="${OPENSEARCH_URL:-}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-}"

# Service names as set by implementations/*/values.yaml fullnameOverride,
# confirmed via `helm template` on 2026-07-24 — EXCEPT OpenSearch, whose
# Service name is NOT controlled by fullnameOverride (see
# implementations/opensearch/values.yaml and README "Verification status"):
# the `helm template` grep match for OpenSearch turned out to be a
# different resource, not the actual Service. The real name
# (opensearch-cluster-master) was only found by running against a live
# cluster and reading `kubectl get svc` — a live run is a stronger check
# than a template grep for exactly this reason.
PROMETHEUS_SVC="${PROMETHEUS_SVC:-ok-observability-prometheus}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
GRAFANA_SVC="${GRAFANA_SVC:-ok-observability-grafana}"
GRAFANA_PORT="${GRAFANA_PORT:-80}"
OPENSEARCH_SVC="${OPENSEARCH_SVC:-opensearch-cluster-master}"
OPENSEARCH_PORT="${OPENSEARCH_PORT:-9200}"
ALERTMANAGER_SVC="${ALERTMANAGER_SVC:-ok-observability-alertmanager}"
ALERTMANAGER_PORT="${ALERTMANAGER_PORT:-9093}"

GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-}"        # Provider Value; required for step 4

# Optional: URL of a receiver-capture endpoint (e.g. a temporary
# webhook-capture pod) to strictly verify alert DELIVERY, not just firing.
# Without it, step 6 only proves the alert reaches Alertmanager — the
# configured production receiver (alerting/alertmanager-values.yaml) is a
# Provider Value placeholder with no real endpoint by default.
CONTRACT_TEST_RECEIVER_CAPTURE_URL="${CONTRACT_TEST_RECEIVER_CAPTURE_URL:-}"

# Unique local ports per run — avoids any collision with a stale/leaked
# forward from a previous run or an unrelated local process (base + a
# stable offset derived from PID, all in the 20000-29999 range).
_PORT_BASE=$(( 20000 + ($$ % 5000) ))
LOCAL_PROMETHEUS_PORT=$(( _PORT_BASE + 1 ))
LOCAL_GRAFANA_PORT=$(( _PORT_BASE + 2 ))
LOCAL_OPENSEARCH_PORT=$(( _PORT_BASE + 3 ))
LOCAL_ALERTMANAGER_PORT=$(( _PORT_BASE + 4 ))
LOCAL_PUSHGATEWAY_PORT=$(( _PORT_BASE + 5 ))

METRIC_NAME="ok_observability_contract_test_metric_${RUN_ID//[^a-zA-Z0-9]/_}"
ALERT_TRIGGER_METRIC="ok_observability_synthetic_alert_trigger"
LOG_MARKER="OK_OBSERVABILITY_CONTRACT_TEST_LOG_MARKER_${RUN_ID//[^a-zA-Z0-9]/_}"
PUSHGATEWAY_NAME="ok-observability-contract-test-${RUN_ID//[^a-zA-Z0-9]/-}"

PF_PIDS=()
FAILED=0

# --- Helpers ------------------------------------------------------------
step()  { printf '\n== [%s] %s ==\n' "$1" "$2"; }
ok()    { printf '  ok   %s\n' "$1"; }
fail()  { printf '  FAIL %s\n' "$1" >&2; FAILED=1; }

cleanup() {
  local code=$?
  step CLEANUP "removing test resources (run ${RUN_ID})"
  for pid in "${PF_PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  # One delete call PER KIND, not a single comma-joined command: if any one
  # kind isn't registered on this cluster (e.g. `servicemonitor` when the
  # CRD is missing), kubectl aborts the WHOLE multi-kind delete before
  # touching the others — silently leaking the Deployment/Service/Pod that
  # otherwise would have been deleted just fine. `--ignore-not-found` only
  # covers a missing *named* object, not a missing *resource type*. Found
  # by exactly this leak on ok-shared (no ServiceMonitor CRD there).
  for kind in deploy svc job pod configmap servicemonitor; do
    kubectl -n "$NAMESPACE" delete "$kind" \
      -l "app.kubernetes.io/managed-by=ok-observability-contract-test,run-id=${RUN_ID}" \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  exit "$code"
}
trap cleanup EXIT INT TERM

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "FAIL: required binary '$1' not found on PATH" >&2
    exit 2
  }
}

# require_service <name> <namespace> — fail fast with a clear, actionable
# message instead of silently port-forwarding to nothing (see header note).
require_service() {
  kubectl -n "$2" get "svc/$1" >/dev/null 2>&1
}

# port_forward <service> <remote-port> <local-port> <health-path>
# Verifies the forward is actually serving traffic before returning —
# fails loudly (not a silent, later-misdiagnosed timeout) if it isn't.
port_forward() {
  local svc="$1" remote="$2" local_port="$3" health="${4:-/}"
  kubectl -n "$NAMESPACE" port-forward "svc/${svc}" "${local_port}:${remote}" \
    >/tmp/pf-"${svc}"-"${RUN_ID}".log 2>&1 &
  local pid=$!
  PF_PIDS+=("$pid")

  local waited=0
  until curl -sf -o /dev/null "http://localhost:${local_port}${health}" 2>/dev/null; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "  port-forward to svc/${svc} exited early:" >&2
      sed 's/^/    /' "/tmp/pf-${svc}-${RUN_ID}.log" >&2
      return 1
    fi
    waited=$((waited + 1))
    if [ "$waited" -ge 15 ]; then
      echo "  port-forward to svc/${svc} did not become healthy within 15s" >&2
      return 1
    fi
    sleep 1
  done
  return 0
}

wait_for() {
  # wait_for <description> <command...>
  # NOTE: pass commands that already `set -o pipefail` internally if they
  # pipe curl into jq/grep — see header note.
  local desc="$1"; shift
  local waited=0
  until "$@" >/dev/null 2>&1; do
    waited=$((waited + POLL_INTERVAL))
    if [ "$waited" -ge "$TIMEOUT" ]; then
      echo "  ...timed out after ${TIMEOUT}s waiting for: $desc" >&2
      return 1
    fi
    sleep "$POLL_INTERVAL"
  done
  return 0
}

# --- Preconditions --------------------------------------------------------
require_bin kubectl
require_bin curl
require_bin jq

kubectl cluster-info >/dev/null 2>&1 || {
  echo "FAIL: kubectl cannot reach a cluster (check KUBECONFIG)" >&2
  exit 2
}
echo "Context: $(kubectl config current-context 2>&1) | Namespace: ${NAMESPACE} | Run: ${RUN_ID}"

if ! kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
  echo "FAIL: CRD servicemonitors.monitoring.coreos.com not found on this cluster." >&2
  echo "      implementations/prometheus (kube-prometheus-stack, which ships the" >&2
  echo "      Prometheus Operator + its CRDs) does not appear to be installed here." >&2
  echo "      Install the ok-observability-standard profile on this cluster first" >&2
  echo "      (see profiles/ok-observability-standard/README.md) before running" >&2
  echo "      this gate — it cannot validate guarantees that aren't deployed." >&2
  exit 1
fi

# Fail fast per-service instead of silently forwarding to nothing and
# timing out 120s later with a misleading diagnostic.
PROM_AVAILABLE=1; GRAFANA_AVAILABLE=1; OS_AVAILABLE=1; AM_AVAILABLE=1

if [ -z "$PROMETHEUS_URL" ]; then
  if require_service "$PROMETHEUS_SVC" "$NAMESPACE" \
      && port_forward "$PROMETHEUS_SVC" "$PROMETHEUS_PORT" "$LOCAL_PROMETHEUS_PORT" "/-/healthy"; then
    PROMETHEUS_URL="http://localhost:${LOCAL_PROMETHEUS_PORT}"
  else
    fail "svc/${PROMETHEUS_SVC} not reachable in namespace ${NAMESPACE} — is implementations/prometheus installed here?"
    PROM_AVAILABLE=0
  fi
fi
if [ -z "$GRAFANA_URL" ]; then
  if require_service "$GRAFANA_SVC" "$NAMESPACE" \
      && port_forward "$GRAFANA_SVC" "$GRAFANA_PORT" "$LOCAL_GRAFANA_PORT" "/api/health"; then
    GRAFANA_URL="http://localhost:${LOCAL_GRAFANA_PORT}"
  else
    fail "svc/${GRAFANA_SVC} not reachable in namespace ${NAMESPACE} — is implementations/grafana installed here?"
    GRAFANA_AVAILABLE=0
  fi
fi
if [ -z "$OPENSEARCH_URL" ]; then
  if require_service "$OPENSEARCH_SVC" "$NAMESPACE" \
      && port_forward "$OPENSEARCH_SVC" "$OPENSEARCH_PORT" "$LOCAL_OPENSEARCH_PORT" "/"; then
    OPENSEARCH_URL="http://localhost:${LOCAL_OPENSEARCH_PORT}"
  else
    fail "svc/${OPENSEARCH_SVC} not reachable in namespace ${NAMESPACE} — is implementations/opensearch installed here?"
    OS_AVAILABLE=0
  fi
fi
if [ -z "$ALERTMANAGER_URL" ]; then
  if require_service "$ALERTMANAGER_SVC" "$NAMESPACE" \
      && port_forward "$ALERTMANAGER_SVC" "$ALERTMANAGER_PORT" "$LOCAL_ALERTMANAGER_PORT" "/-/healthy"; then
    ALERTMANAGER_URL="http://localhost:${LOCAL_ALERTMANAGER_PORT}"
  else
    fail "svc/${ALERTMANAGER_SVC} not reachable in namespace ${NAMESPACE} — is implementations/prometheus (Alertmanager) installed here?"
    AM_AVAILABLE=0
  fi
fi

# --- Step 1+2: deploy synthetic workload, register declaratively --------
step 1-2 "deploy synthetic workload (Pushgateway) + ServiceMonitor"

apply_out=$(kubectl -n "$NAMESPACE" apply -f - 2>&1 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PUSHGATEWAY_NAME}
  labels:
    app.kubernetes.io/managed-by: ok-observability-contract-test
    run-id: "${RUN_ID}"
spec:
  replicas: 1
  selector:
    matchLabels: {app: "${PUSHGATEWAY_NAME}"}
  template:
    metadata:
      labels: {app: "${PUSHGATEWAY_NAME}"}
    spec:
      containers:
        - name: pushgateway
          image: prom/pushgateway:v1.9.0
          ports: [{containerPort: 9091, name: http}]
---
apiVersion: v1
kind: Service
metadata:
  name: ${PUSHGATEWAY_NAME}
  labels:
    app.kubernetes.io/managed-by: ok-observability-contract-test
    run-id: "${RUN_ID}"
spec:
  selector: {app: "${PUSHGATEWAY_NAME}"}
  ports: [{port: 9091, targetPort: 9091, name: http}]
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ${PUSHGATEWAY_NAME}
  labels:
    app.kubernetes.io/managed-by: ok-observability-contract-test
    run-id: "${RUN_ID}"
    release: ok-observability
spec:
  selector:
    matchLabels: {app: "${PUSHGATEWAY_NAME}"}
  endpoints:
    - port: http
      interval: 10s
EOF
)
apply_rc=$?
echo "$apply_out"
if [ "$apply_rc" -ne 0 ]; then
  fail "kubectl apply reported errors (see output above) — deployment, Service, and/or ServiceMonitor may not all exist"
fi

if kubectl -n "$NAMESPACE" rollout status "deploy/${PUSHGATEWAY_NAME}" --timeout="${TIMEOUT}s" >/dev/null 2>&1; then
  ok "synthetic workload (Pushgateway) ready"
else
  fail "synthetic workload did not become ready in time"
fi

if kubectl -n "$NAMESPACE" get "servicemonitor/${PUSHGATEWAY_NAME}" >/dev/null 2>&1; then
  ok "ServiceMonitor registered (declarative registration, guarantee #1)"
else
  fail "ServiceMonitor was NOT created — Prometheus Operator CRDs likely missing or apply failed above"
fi

if port_forward "$PUSHGATEWAY_NAME" 9091 "$LOCAL_PUSHGATEWAY_PORT" "/-/healthy"; then
  push_out=$(printf '%s %s\n%s %s\n' "$METRIC_NAME" 1 "$ALERT_TRIGGER_METRIC" 1 \
    | curl -sf --data-binary @- "http://localhost:${LOCAL_PUSHGATEWAY_PORT}/metrics/job/${PUSHGATEWAY_NAME}" 2>&1)
  push_rc=$?
  if [ "$push_rc" -eq 0 ]; then
    ok "synthetic metric + alert-trigger metric pushed"
  else
    fail "could not push synthetic metrics to pushgateway: ${push_out}"
  fi
else
  fail "could not reach the synthetic Pushgateway workload itself — see log above"
fi

# --- Step 3: verify Prometheus ingestion ---------------------------------
step 3 "verify Prometheus ingestion"
if [ "$PROM_AVAILABLE" -eq 0 ]; then
  fail "skipped — Prometheus was not reachable (see precondition failure above)"
elif wait_for "Prometheus scrape of ${METRIC_NAME}" bash -c \
    "set -o pipefail; curl -sf '${PROMETHEUS_URL}/api/v1/query' --data-urlencode 'query=${METRIC_NAME}' | jq -e '.data.result | length > 0'"; then
  ok "metric ingested by Prometheus"
else
  fail "metric never appeared in Prometheus within ${TIMEOUT}s"
fi

# --- Step 4: verify visibility via Grafana datasource query --------------
step 4 "verify metric visible via Grafana datasource query"
if [ "$GRAFANA_AVAILABLE" -eq 0 ]; then
  fail "skipped — Grafana was not reachable (see precondition failure above)"
elif [ -z "$GRAFANA_PASSWORD" ]; then
  fail "GRAFANA_PASSWORD not set — cannot authenticate to Grafana (skipping step 4 check, not a PASS)"
else
  ds_uid=$(curl -sf -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" "${GRAFANA_URL}/api/datasources" \
    | jq -r '.[] | select(.type=="prometheus") | .uid' | head -1)
  if [ -z "$ds_uid" ] || [ "$ds_uid" = "null" ]; then
    fail "no Prometheus datasource found in Grafana (check credentials and datasource provisioning)"
  else
    result=$(curl -sf -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" \
      "${GRAFANA_URL}/api/datasources/proxy/uid/${ds_uid}/api/v1/query" \
      --data-urlencode "query=${METRIC_NAME}" | jq -e '.data.result | length > 0' 2>/dev/null)
    [ "$result" = "true" ] && ok "metric visible via Grafana datasource (uid ${ds_uid})" \
      || fail "metric not visible via Grafana datasource proxy query"
  fi
fi

# --- Step 5: synthetic log line, verify searchable in OpenSearch --------
step 5 "emit synthetic log line, verify searchable in OpenSearch"
if [ "$OS_AVAILABLE" -eq 0 ]; then
  fail "skipped — OpenSearch was not reachable (see precondition failure above)"
else
  kubectl -n "$NAMESPACE" run "log-emitter-${RUN_ID//[^a-zA-Z0-9]/-}" \
    --labels="app.kubernetes.io/managed-by=ok-observability-contract-test,run-id=${RUN_ID}" \
    --image=busybox --restart=Never --command -- echo "${LOG_MARKER}" >/dev/null 2>&1

  if wait_for "log marker searchable in OpenSearch" bash -c \
      "set -o pipefail; curl -sf '${OPENSEARCH_URL}/ok-observability-logs*/_search' \
         -H 'Content-Type: application/json' \
         -d '{\"query\":{\"match_phrase\":{\"log\":\"${LOG_MARKER}\"}}}' \
       | jq -e '.hits.total.value > 0'"; then
    ok "log marker found in OpenSearch"
  else
    fail "log marker not found in OpenSearch within ${TIMEOUT}s (check Fluent Bit output config / index name)"
  fi
  kubectl -n "$NAMESPACE" delete pod "log-emitter-${RUN_ID//[^a-zA-Z0-9]/-}" --ignore-not-found --wait=false >/dev/null 2>&1
fi

# --- Step 6: synthetic alert, verify delivery ----------------------------
step 6 "trigger synthetic alert, verify firing + (if configured) delivery"
if [ "$AM_AVAILABLE" -eq 0 ]; then
  fail "skipped — Alertmanager was not reachable (see precondition failure above)"
elif wait_for "OKObservabilitySyntheticAlert firing in Alertmanager" bash -c \
    "set -o pipefail; curl -sf '${ALERTMANAGER_URL}/api/v2/alerts' | jq -e '[.[] | select(.labels.alertname==\"OKObservabilitySyntheticAlert\")] | length > 0'"; then
  ok "synthetic alert reached Alertmanager"

  if [ -n "$CONTRACT_TEST_RECEIVER_CAPTURE_URL" ]; then
    if wait_for "alert payload captured at receiver" bash -c \
        "set -o pipefail; curl -sf '${CONTRACT_TEST_RECEIVER_CAPTURE_URL}' | grep -q OKObservabilitySyntheticAlert"; then
      ok "alert delivery confirmed at capture receiver"
    else
      fail "alert did not reach the configured capture receiver within ${TIMEOUT}s"
    fi
  else
    echo "  WARN: CONTRACT_TEST_RECEIVER_CAPTURE_URL not set — only alert FIRING was" >&2
    echo "        verified, not delivery to a real receiver. The committed receiver" >&2
    echo "        (alerting/alertmanager-values.yaml) is a Provider Value placeholder" >&2
    echo "        with no working endpoint by default. This is a known gap, not a" >&2
    echo "        silent pass — see tests/README.md." >&2
  fi
else
  fail "synthetic alert never appeared in Alertmanager within ${TIMEOUT}s"
fi

# --- Result ---------------------------------------------------------------
echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "CONTRACT TEST: PASS — all five guarantees verified (run ${RUN_ID})"
  exit 0
else
  echo "CONTRACT TEST: FAIL — see above (run ${RUN_ID})" >&2
  exit 1
fi
