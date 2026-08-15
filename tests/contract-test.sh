#!/usr/bin/env bash
# Contract Test — Provisioning Readiness Gate (ADR-Platform-018)
#
# Verifies the five Observability Capability Contract v1 guarantees against
# a live cluster where the ok-observability-standard profile is installed.
# See tests/README.md for the verification sequence this implements.
#
# Requires: kubectl (pointed at the target cluster via KUBECONFIG), curl, jq.
# Provider Values for this test are environment variables — see the
# defaults below. Two are Provider-Value passwords: GRAFANA_PASSWORD (step 4)
# and OPENSEARCH_PASSWORD (step 5); export them for a full run (never commit
# them — they live in ok-cluster). A real alert-receiver endpoint is a
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

if [[ $- == *x* ]]; then
  set +x
  echo "WARN: shell xtrace disabled to protect Provider-Value credentials" >&2
fi

# --- Configuration (Provider Values for this test run) ----------------------
NAMESPACE="${CONTRACT_TEST_NAMESPACE:-ok-observability}"
RUN_ID="${CONTRACT_TEST_RUN_ID:-$(date +%s)-$$}"
# Default 240s (not 120): the slowest async check is the Prometheus scrape
# of a FRESH ServiceMonitor, which waits on the Prometheus Operator to
# reconcile + regenerate + hot-reload the scrape config. Measured live at
# ~120–135s on ok-robotics — i.e. right at the old 120s edge, so 120 flaked
# intermittently (metric DID arrive, just after the window; proven by step 6
# passing in the same run where step 3 timed out). 240 gives realistic
# head-room without masking a real failure. Override per-run if needed.
TIMEOUT="${CONTRACT_TEST_TIMEOUT:-240}"       # seconds to wait per async check
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

# OpenSearch's security plugin is enabled (see implementations/opensearch):
# it serves HTTPS with a self-signed demo cert and requires Basic Auth even
# for reads. The reachability probe (step "preconditions") and the log search
# (step 5) therefore speak https + -k + these credentials. Empty password =>
# step 5 fails with an actionable message, not a silent pass.
OPENSEARCH_USER="${OPENSEARCH_USER:-admin}"
OPENSEARCH_PASSWORD="${OPENSEARCH_PASSWORD:-}"  # Provider Value; required for step 5

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

# Kubernetes Service names and label values are limited to 63 characters.
# A descriptive prefix plus an otherwise valid long RUN_ID used to exceed
# that boundary: the ServiceMonitor could be created while the Deployment
# and Service were rejected, producing a misleading Prometheus timeout.
# Keep a readable prefix and add the POSIX cksum of the full RUN_ID so
# different long IDs cannot silently collapse to the same truncated value.
command -v cksum >/dev/null 2>&1 || {
  echo "FAIL: required binary 'cksum' not found on PATH" >&2
  exit 2
}
RUN_SLUG="${RUN_ID//[^a-zA-Z0-9]/-}"
RUN_CKSUM="$(printf '%s' "$RUN_ID" | cksum)"
RUN_CKSUM="${RUN_CKSUM%% *}"
RUN_LABEL="${RUN_SLUG:0:46}-${RUN_CKSUM}"
PUSHGATEWAY_NAME="oo-ct-${RUN_LABEL}"
LOG_EMITTER_NAME="oo-log-${RUN_LABEL}"

if [ "${#RUN_LABEL}" -gt 57 ] || [ "${#PUSHGATEWAY_NAME}" -gt 63 ] \
    || [ "${#LOG_EMITTER_NAME}" -gt 63 ]; then
  echo "FAIL: internal bounded-name invariant exceeded" >&2
  exit 2
fi

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
      -l "app.kubernetes.io/managed-by=ok-observability-contract-test,run-id=${RUN_LABEL}" \
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

# curl_basic_auth <user-variable> <password-variable> <curl-arguments...>
# Supplies Basic Auth through curl's stdin config so credentials never enter
# curl's process arguments.
curl_basic_auth() {
  local user_name="$1" password_name="$2" user_config
  shift 2

  user_config="${!user_name}:${!password_name}"
  user_config="${user_config//\\/\\\\}"
  user_config="${user_config//\"/\\\"}"
  user_config="${user_config//$'\t'/\\t}"
  user_config="${user_config//$'\r'/\\r}"
  user_config="${user_config//$'\n'/\\n}"

  printf 'user = "%s"\n' "$user_config" | curl --config - "$@"
  local pipeline_status=("${PIPESTATUS[@]}")
  return "${pipeline_status[1]}"
}

# capture_http <user-variable> <password-variable> <curl-arguments...>
# Retains the response status and body without putting credentials in argv.
# Its return status matches curl -f for the responses used by this gate:
# transport failures retain curl's status, and HTTP 4xx/5xx returns 22.
HTTP_STATUS=000
HTTP_BODY=""
HTTP_CURL_ERROR=""
HTTP_CURL_RC=0
capture_http() {
  local user_name="$1" password_name="$2" body_file error_file
  shift 2

  HTTP_STATUS=000
  HTTP_BODY=""
  HTTP_CURL_ERROR=""
  HTTP_CURL_RC=0

  body_file=$(mktemp) || {
    HTTP_CURL_RC=1
    return 1
  }
  error_file=$(mktemp) || {
    HTTP_CURL_RC=1
    rm -f "$body_file"
    return 1
  }

  HTTP_STATUS=$(curl_basic_auth "$user_name" "$password_name" "$@" \
    -sS -o "$body_file" -w '%{http_code}' 2>"$error_file")
  HTTP_CURL_RC=$?
  HTTP_BODY=$(<"$body_file")
  HTTP_CURL_ERROR=$(<"$error_file")
  rm -f "$body_file" "$error_file"

  [ "$HTTP_CURL_RC" -eq 0 ] || return "$HTTP_CURL_RC"
  if [[ "$HTTP_STATUS" =~ ^[45][0-9][0-9]$ ]]; then
    return 22
  fi
  return 0
}

# http_failure_detail <credential-hint> <http-200-absence-detail>
http_failure_detail() {
  local credential_hint="$1" absence_detail="$2"

  if [ "$HTTP_CURL_RC" -ne 0 ]; then
    printf 'transport failure (curl exit %s) — no HTTP response; check service and port-forward reachability' \
      "$HTTP_CURL_RC"
  elif [ "$HTTP_STATUS" = "401" ] || [ "$HTTP_STATUS" = "403" ]; then
    printf 'authentication failed (HTTP %s) — check %s' "$HTTP_STATUS" "$credential_hint"
  elif [[ "$HTTP_STATUS" =~ ^[45][0-9][0-9]$ ]]; then
    printf 'request failed (HTTP %s) — check the service response and configuration' "$HTTP_STATUS"
  elif [ "$HTTP_STATUS" = "200" ]; then
    printf 'HTTP 200 but %s' "$absence_detail"
  else
    printf 'unexpected HTTP status %s — check the service response and configuration' "$HTTP_STATUS"
  fi
}

# port_forward <service> <remote-port> <local-port> <health-path> [scheme] [user-variable] [password-variable]
# scheme defaults to http; pass "https" for TLS services (adds -k for the
# self-signed cert). user-variable and password-variable are optional variable
# names for Basic Auth (OpenSearch's security plugin). Verifies the forward is
# actually serving traffic before returning — fails loudly (not a silent,
# later-misdiagnosed timeout) if it isn't.
port_forward() {
  local svc="$1" remote="$2" local_port="$3" health="${4:-/}" scheme="${5:-http}"
  local user_name="${6:-}" password_name="${7:-}"
  kubectl -n "$NAMESPACE" port-forward "svc/${svc}" "${local_port}:${remote}" \
    >/tmp/pf-"${svc}"-"${RUN_ID}".log 2>&1 &
  local pid=$!
  PF_PIDS+=("$pid")

  local opts=(-sf -o /dev/null)
  local health_check=(curl)
  if [ -n "$user_name" ]; then
    opts=(-sS)
    health_check=(capture_http "$user_name" "$password_name")
  fi
  [ "$scheme" = "https" ] && opts+=(-k)

  local waited=0
  until "${health_check[@]}" "${opts[@]}" "${scheme}://localhost:${local_port}${health}" 2>/dev/null; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "  port-forward to svc/${svc} exited early:" >&2
      sed 's/^/    /' "/tmp/pf-${svc}-${RUN_ID}.log" >&2
      if [ -n "$user_name" ]; then
        echo "  health probe for svc/${svc} failed: $(http_failure_detail \
          "${user_name}/${password_name}" "the health endpoint did not confirm readiness")" >&2
      fi
      return 1
    fi
    waited=$((waited + 1))
    if [ "$waited" -ge 15 ]; then
      echo "  port-forward to svc/${svc} did not become healthy within 15s" >&2
      if [ -n "$user_name" ]; then
        echo "  health probe for svc/${svc} failed: $(http_failure_detail \
          "${user_name}/${password_name}" "the health endpoint did not confirm readiness")" >&2
      fi
      return 1
    fi
    sleep 1
  done
  return 0
}

opensearch_log_present() {
  capture_http OPENSEARCH_USER OPENSEARCH_PASSWORD -sk \
    "${OPENSEARCH_URL}/ok-observability-logs*/_search" \
    -H 'Content-Type: application/json' \
    -d "{\"query\":{\"match_phrase\":{\"log\":\"${LOG_MARKER}\"}}}" \
    || return $?
  jq -e '.hits.total.value > 0' <<<"$HTTP_BODY"
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
      && port_forward "$OPENSEARCH_SVC" "$OPENSEARCH_PORT" "$LOCAL_OPENSEARCH_PORT" \
           "/_cluster/health" "https" OPENSEARCH_USER OPENSEARCH_PASSWORD; then
    OPENSEARCH_URL="https://localhost:${LOCAL_OPENSEARCH_PORT}"
  else
    fail "svc/${OPENSEARCH_SVC} not reachable/authenticated in namespace ${NAMESPACE} — is implementations/opensearch installed, and is OPENSEARCH_PASSWORD set? (security plugin = HTTPS + Basic Auth)"
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
    run-id: "${RUN_LABEL}"
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
    # The 'app' label MUST be here in the Service's METADATA labels (not just
    # in spec.selector): the ServiceMonitor below selects Services by their
    # metadata labels, so without this the operator generates no scrape
    # target and the pushed metric never reaches Prometheus (silent — the
    # workload deploys fine, it is just never scraped).
    # NOTE: no backticks in this heredoc — it is unquoted, so backticks would
    # trigger command substitution.
    app: "${PUSHGATEWAY_NAME}"
    app.kubernetes.io/managed-by: ok-observability-contract-test
    run-id: "${RUN_LABEL}"
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
    run-id: "${RUN_LABEL}"
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
  if ! capture_http GRAFANA_USER GRAFANA_PASSWORD "${GRAFANA_URL}/api/datasources"; then
    fail "Grafana datasource discovery failed: $(http_failure_detail \
      "GRAFANA_USER/GRAFANA_PASSWORD" "no Prometheus datasource was found — check datasource provisioning")"
  else
    ds_uid=$(jq -r '.[] | select(.type=="prometheus") | .uid' <<<"$HTTP_BODY" 2>/dev/null \
      | head -1)
    if [ -z "$ds_uid" ] || [ "$ds_uid" = "null" ]; then
      fail "Grafana datasource discovery failed: $(http_failure_detail \
        "GRAFANA_USER/GRAFANA_PASSWORD" "no Prometheus datasource was found — check datasource provisioning")"
    elif ! capture_http GRAFANA_USER GRAFANA_PASSWORD \
        "${GRAFANA_URL}/api/datasources/proxy/uid/${ds_uid}/api/v1/query" \
        --data-urlencode "query=${METRIC_NAME}"; then
      fail "Grafana datasource proxy query failed: $(http_failure_detail \
        "GRAFANA_USER/GRAFANA_PASSWORD" "the synthetic metric was absent — check Prometheus ingestion and datasource configuration")"
    elif jq -e '.data.result | length > 0' <<<"$HTTP_BODY" >/dev/null 2>&1; then
      ok "metric visible via Grafana datasource (uid ${ds_uid})"
    else
      fail "Grafana datasource proxy query failed: $(http_failure_detail \
        "GRAFANA_USER/GRAFANA_PASSWORD" "the synthetic metric was absent — check Prometheus ingestion and datasource configuration")"
    fi
  fi
fi

# --- Step 5: synthetic log line, verify searchable in OpenSearch --------
step 5 "emit synthetic log line, verify searchable in OpenSearch"
if [ "$OS_AVAILABLE" -eq 0 ]; then
  fail "skipped — OpenSearch was not reachable (see precondition failure above)"
else
  kubectl -n "$NAMESPACE" run "$LOG_EMITTER_NAME" \
    --labels="app.kubernetes.io/managed-by=ok-observability-contract-test,run-id=${RUN_LABEL}" \
    --image=busybox --restart=Never --command -- echo "${LOG_MARKER}" >/dev/null 2>&1

  if wait_for "log marker searchable in OpenSearch" opensearch_log_present; then
    ok "log marker found in OpenSearch"
  else
    fail "OpenSearch log search failed after ${TIMEOUT}s: $(http_failure_detail \
      "OPENSEARCH_USER/OPENSEARCH_PASSWORD" "the log marker was absent — check Fluent Bit output config and index name")"
  fi
  kubectl -n "$NAMESPACE" delete pod "$LOG_EMITTER_NAME" --ignore-not-found --wait=false >/dev/null 2>&1
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
