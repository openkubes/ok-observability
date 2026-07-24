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
set -uo pipefail

# --- Configuration (Provider Values for this test run) ----------------------
NAMESPACE="${CONTRACT_TEST_NAMESPACE:-default}"
RUN_ID="${CONTRACT_TEST_RUN_ID:-$(date +%s)-$$}"
TIMEOUT="${CONTRACT_TEST_TIMEOUT:-120}"       # seconds to wait per async check
POLL_INTERVAL="${CONTRACT_TEST_POLL_INTERVAL:-5}"

PROMETHEUS_URL="${PROMETHEUS_URL:-}"           # empty => port-forward is used
GRAFANA_URL="${GRAFANA_URL:-}"
OPENSEARCH_URL="${OPENSEARCH_URL:-}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-}"

# Service names as set by implementations/*/values.yaml fullnameOverride.
# NOT independently verified against a live helm template render — see
# implementations/*/README.md "Verification status". Correct here if they
# differ once verified.
PROMETHEUS_SVC="${PROMETHEUS_SVC:-svc/ok-observability-prometheus}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
GRAFANA_SVC="${GRAFANA_SVC:-svc/ok-observability-grafana}"
GRAFANA_PORT="${GRAFANA_PORT:-80}"
OPENSEARCH_SVC="${OPENSEARCH_SVC:-svc/ok-observability-opensearch}"
OPENSEARCH_PORT="${OPENSEARCH_PORT:-9200}"
ALERTMANAGER_SVC="${ALERTMANAGER_SVC:-svc/ok-observability-alertmanager}"
ALERTMANAGER_PORT="${ALERTMANAGER_PORT:-9093}"

GRAFANA_USER="${GRAFANA_USER:-admin}"
GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-}"        # Provider Value; required for step 4

# Optional: URL of a receiver-capture endpoint (e.g. a temporary
# webhook-capture pod) to strictly verify alert DELIVERY, not just firing.
# Without it, step 6 only proves the alert reaches Alertmanager — the
# configured production receiver (alerting/alertmanager-values.yaml) is a
# Provider Value placeholder with no real endpoint by default.
CONTRACT_TEST_RECEIVER_CAPTURE_URL="${CONTRACT_TEST_RECEIVER_CAPTURE_URL:-}"

METRIC_NAME="ok_observability_contract_test_metric_${RUN_ID//[^a-zA-Z0-9]/_}"
ALERT_TRIGGER_METRIC="ok_observability_synthetic_alert_trigger"
LOG_MARKER="OK_OBSERVABILITY_CONTRACT_TEST_LOG_MARKER_${RUN_ID//[^a-zA-Z0-9]/_}"
PUSHGATEWAY_NAME="ok-observability-contract-test-${RUN_ID//[^a-zA-Z0-9]/-}"

PF_PIDS=()

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
  kubectl -n "$NAMESPACE" delete deploy,svc,job,configmap,servicemonitor \
    -l "app.kubernetes.io/managed-by=ok-observability-contract-test,run-id=${RUN_ID}" \
    --ignore-not-found --wait=false >/dev/null 2>&1 || true
  exit "$code"
}
trap cleanup EXIT INT TERM

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "FAIL: required binary '$1' not found on PATH" >&2
    exit 2
  }
}

port_forward() {
  # port_forward <service> <remote-port> <local-port>
  kubectl -n "$NAMESPACE" port-forward "$1" "$3:$2" >/dev/null 2>&1 &
  PF_PIDS+=("$!")
  sleep 2
}

wait_for() {
  # wait_for <description> <command...>
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
FAILED=0

kubectl cluster-info >/dev/null 2>&1 || {
  echo "FAIL: kubectl cannot reach a cluster (check KUBECONFIG)" >&2
  exit 2
}

if [ -z "$PROMETHEUS_URL" ]; then
  port_forward "$PROMETHEUS_SVC" "$PROMETHEUS_PORT" 19090
  PROMETHEUS_URL="http://localhost:19090"
fi
if [ -z "$GRAFANA_URL" ]; then
  port_forward "$GRAFANA_SVC" "$GRAFANA_PORT" 13000
  GRAFANA_URL="http://localhost:13000"
fi
if [ -z "$OPENSEARCH_URL" ]; then
  port_forward "$OPENSEARCH_SVC" "$OPENSEARCH_PORT" 19200
  OPENSEARCH_URL="http://localhost:19200"
fi
if [ -z "$ALERTMANAGER_URL" ]; then
  port_forward "$ALERTMANAGER_SVC" "$ALERTMANAGER_PORT" 19093
  ALERTMANAGER_URL="http://localhost:19093"
fi

# --- Step 1+2: deploy synthetic workload, register declaratively --------
step 1-2 "deploy synthetic workload (Pushgateway) + ServiceMonitor"

kubectl -n "$NAMESPACE" apply -f - >/dev/null <<EOF
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

kubectl -n "$NAMESPACE" rollout status "deploy/${PUSHGATEWAY_NAME}" --timeout="${TIMEOUT}s" \
  && ok "synthetic workload ready + ServiceMonitor applied" \
  || fail "synthetic workload did not become ready in time"

port_forward "svc/${PUSHGATEWAY_NAME}" 9091 19091
cat <<EOF | curl -sf --data-binary @- "http://localhost:19091/metrics/job/${PUSHGATEWAY_NAME}"
${METRIC_NAME} 1
${ALERT_TRIGGER_METRIC} 1
EOF
[ $? -eq 0 ] && ok "synthetic metric + alert-trigger metric pushed" \
  || fail "could not push synthetic metrics to pushgateway"

# --- Step 3: verify Prometheus ingestion ---------------------------------
step 3 "verify Prometheus ingestion"
prom_query() { curl -sf "${PROMETHEUS_URL}/api/v1/query" --data-urlencode "query=$1"; }

if wait_for "Prometheus scrape of ${METRIC_NAME}" bash -c \
    "curl -sf '${PROMETHEUS_URL}/api/v1/query' --data-urlencode 'query=${METRIC_NAME}' | jq -e '.data.result | length > 0'"; then
  ok "metric ingested by Prometheus"
else
  fail "metric never appeared in Prometheus within ${TIMEOUT}s"
fi

# --- Step 4: verify visibility via Grafana datasource query --------------
step 4 "verify metric visible via Grafana datasource query"
if [ -z "$GRAFANA_PASSWORD" ]; then
  fail "GRAFANA_PASSWORD not set — cannot authenticate to Grafana (skipping step 4 check, not a PASS)"
else
  ds_uid=$(curl -sf -u "${GRAFANA_USER}:${GRAFANA_PASSWORD}" "${GRAFANA_URL}/api/datasources" \
    | jq -r '.[] | select(.type=="prometheus") | .uid' | head -1)
  if [ -z "$ds_uid" ] || [ "$ds_uid" = "null" ]; then
    fail "no Prometheus datasource found in Grafana"
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
kubectl -n "$NAMESPACE" run "log-emitter-${RUN_ID//[^a-zA-Z0-9]/-}" \
  --labels="app.kubernetes.io/managed-by=ok-observability-contract-test,run-id=${RUN_ID}" \
  --image=busybox --restart=Never --command -- echo "${LOG_MARKER}" >/dev/null 2>&1

if wait_for "log marker searchable in OpenSearch" bash -c \
    "curl -sf '${OPENSEARCH_URL}/ok-observability-logs*/_search' \
       -H 'Content-Type: application/json' \
       -d '{\"query\":{\"match_phrase\":{\"log\":\"${LOG_MARKER}\"}}}' \
     | jq -e '.hits.total.value > 0'"; then
  ok "log marker found in OpenSearch"
else
  fail "log marker not found in OpenSearch within ${TIMEOUT}s (check Fluent Bit output config / index name)"
fi
kubectl -n "$NAMESPACE" delete pod "log-emitter-${RUN_ID//[^a-zA-Z0-9]/-}" --ignore-not-found --wait=false >/dev/null 2>&1

# --- Step 6: synthetic alert, verify delivery ----------------------------
step 6 "trigger synthetic alert, verify firing + (if configured) delivery"
if wait_for "OKObservabilitySyntheticAlert firing in Alertmanager" bash -c \
    "curl -sf '${ALERTMANAGER_URL}/api/v2/alerts' | jq -e '[.[] | select(.labels.alertname==\"OKObservabilitySyntheticAlert\")] | length > 0'"; then
  ok "synthetic alert reached Alertmanager"
else
  fail "synthetic alert never appeared in Alertmanager within ${TIMEOUT}s"
fi

if [ -n "$CONTRACT_TEST_RECEIVER_CAPTURE_URL" ]; then
  if wait_for "alert payload captured at receiver" bash -c \
      "curl -sf '${CONTRACT_TEST_RECEIVER_CAPTURE_URL}' | grep -q OKObservabilitySyntheticAlert"; then
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

# --- Result ---------------------------------------------------------------
echo ""
if [ "${FAILED:-0}" -eq 0 ]; then
  echo "CONTRACT TEST: PASS — all five guarantees verified (run ${RUN_ID})"
  exit 0
else
  echo "CONTRACT TEST: FAIL — see above (run ${RUN_ID})" >&2
  exit 1
fi
