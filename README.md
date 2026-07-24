# ok-observability

**OpenKubes Observability Capability**

> Every OpenKubes cluster provides a local observability capability.

This repository owns the OpenKubes Observability Capability: its contract, reference implementation assets, profiles, and contract tests.

Established by **ADR-Platform-018** (`openkubes/openkubes`, commit `28f88e5`): *Observability Capability — Per-Cluster Stack*.

## Ownership model

Following the ok-storage precedent:

- **ok-observability owns** the capability — contracts, charts/kustomizations, Grafana provisioning, dashboards, Prometheus rules, Alertmanager configuration, OpenSearch templates, index lifecycle policies, contract tests, and documentation.
- **ok-cluster consumes** the capability — it installs and integrates the stack during cluster provisioning, but does not own its assets.

## The chain

```
Capability:              Observability
Contract:                Observability Capability Contract v1 (contracts/)
Implementation Profile:  ok-observability-standard (profiles/)
Provider Values:         storageClass, retention, resources, alert receiver, ingress
```

## Contract v1 — guarantees

An OpenKubes cluster is considered successfully provisioned only after these guarantees have been verified:

1. **Metrics** — declarative registration (ServiceMonitor/PodMonitor semantics); platform components scraped by default
2. **Dashboards** — Grafana reachable in-cluster, platform dashboards pre-provisioned
3. **Logs** — platform and workload container logs collected per declared logging policy, searchable via the cluster-local log backend
4. **Alerting** — alerts deliverable to a cluster-defined receiver endpoint
5. **Autonomy** — the stack functions without cross-cluster connectivity (air-gap compatible, no management-cluster dependency)

The contract test (`tests/contract-test.sh`) verifies all five guarantees. A cluster is not fully provisioned until it passes. It is implemented and has passed on two independent clusters (ok-shared, ok-robotics) via the gated install path (OK-79).

## Reference implementation (ok-observability-standard)

- **Metrics & Dashboards:** kube-prometheus-stack (Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter)
- **Logs:** OpenSearch + log collector

Constraint envelopes (ADR-Platform-017) may substitute this reference implementation with a profile-specific variant without changing the contract.

## Repository guide & verification workflow

New here — human or AI agent — start with [`AGENTS.md`](./AGENTS.md): repository purpose, governing ADRs, prohibited/restricted changes, and escalation rules. Its rule zero: *AI may analyze, propose, implement, and argue; only humans approve architecture decisions and merge changes.*

Before proposing any change, run the deterministic checks:

```
make verify        # fast repo checks: structure, links, secrets, chart structure
make conformance   # the ADR-018 Contract Test Gate (tests/contract-test.sh)
make evidence      # a Jira-comment-ready evidence block from verify + conformance
```

All three are deterministic and independent of any LLM. An AI review may comment on a PR but is advisory only — never a gate. This harness was validated by the OK-100 Harness Engineering pilot (verdict: **adopt**).

## Installation & credentials

The stack is installed per cluster by ok-cluster's gated `make install-observability` (OK-79): it deploys the `ok-observability-standard` profile and runs the contract test, failing unless all five guarantees pass. Admin credentials are read from a Kubernetes Secret `ok-observability-credentials` (Grafana `admin.existingSecret`, OpenSearch `secretKeyRef`, Fluent Bit `${OPENSEARCH_PASSWORD}`) — no plaintext passwords are passed to Helm. Provider Values (`*.provider-values.yaml`) are git-ignored and live in ok-cluster, never here. A later phase replaces Secret creation with an External-Secrets sync from the ok-shared Vault, with no chart change (OK-109).

## Repository layout

```
contracts/          Observability Capability Contract (versioned)
implementations/    Reference implementation assets (prometheus/, grafana/, opensearch/)
profiles/           Implementation profiles (ok-observability-standard/, later: edge-constrained)
dashboards/         Platform Grafana dashboards
alerting/           Alertmanager configuration, Prometheus rules
tests/              Contract test (provisioning readiness gate) — contract-test.sh
scripts/            Deterministic check implementations used by the Makefile
architecture/       Repo-local ADRs (platform ADRs live in openkubes/openkubes)
```

## Explicitly out of scope (v1)

- Cross-cluster federation / long-term aggregation
- Tracing and profiling
- Native OTLP ingestion — workloads that expose telemetry exclusively via OTLP require an additional collector or protocol bridge outside the v1 contract. A Collector-based OTLP pipeline is the designated path for a future contract extension.

## Related

- ADR-Platform-018 — Observability Capability (this repo's founding decision)
- ADR-Platform-001 — Contracts over components
- ADR-Platform-009 — Storage (ownership/consumption precedent)
- ADR-Platform-017 — Constraint Envelopes
- Jira: OK-77 (ADR-018), OK-79 (gated install path — done), OK-100 (Harness Engineering pilot — adopted), OK-109 (follow-up: full re-verify + Vault phase 2), OK-78/OK-80 (parked)
