# alerting/

Alertmanager configuration and Prometheus rules for the Alerting guarantee
(ADR-Platform-018 #4) — kept physically separate from `implementations/prometheus`
so that alert-receiver Provider Values don't get tangled with metrics values.

## Contents

| File | Purpose |
|---|---|
| `prometheus-rules.yaml` | `PrometheusRule` CRD manifest — platform-level alert rules. Picked up cluster-wide because `implementations/prometheus` sets `ruleSelectorNilUsesHelmValues: false`. |
| `alertmanager-values.yaml` | A values *fragment*, layered on top of `implementations/prometheus` at install time (`-f alerting/alertmanager-values.yaml`) — routing and receivers. |

## Provider Value: alert receiver

`alertmanager-values.yaml` ships a placeholder receiver
(`default-receiver`, no actual endpoint configured). Per-cluster receiver
configuration (webhook, email, PagerDuty, etc.) is a Provider Value and
**must** be overridden — this file documents the shape, not a working
default. This is exactly the "synthetic alert → verify delivery at
receiver" step the contract test (OK-79) needs to exercise; without a real
receiver configured, that step cannot pass on a live cluster.

## Usage

Layered at install time, not standalone:

```shell
helm template implementations/prometheus \
  -f implementations/prometheus/values.yaml \
  -f alerting/alertmanager-values.yaml \
  -f <cluster-provider-values.yaml>

kubectl apply -f alerting/prometheus-rules.yaml
```
