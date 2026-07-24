# implementations/opensearch

Reference implementation of ADR-Platform-018 guarantee **#3 Logs**, via
[opensearch-project/helm-charts](https://github.com/opensearch-project/helm-charts)
(`opensearch` chart) plus [fluent/helm-charts](https://github.com/fluent/helm-charts)
(`fluent-bit` chart) as the log collector, both pinned in `Chart.yaml`.

## What this owns

- OpenSearch (single-node-capable in v1)
- Fluent Bit, shipping container logs per the default logging policy (all
  container logs)

## Known gap (tracked, not silent)

No index lifecycle / retention policy ships by default. Applying one
(OpenSearch ISM plugin, or an external curator) is a Provider Value
follow-up — flagged in `values.yaml` rather than silently omitted.

## Provider Values

| Value | Where | Default here |
|---|---|---|
| `storageClass` | `opensearch.persistence.storageClass` | `""` (cluster default) |
| `OPENSEARCH_INITIAL_ADMIN_PASSWORD` | `opensearch.extraEnvs` | `""` — **REQUIRED**, install fails without it (OpenSearch 2.12+) |
| retention / ILM | not yet implemented | see "Known gap" above |
| log exclusions | `fluent-bit.config.outputs` (add a `[FILTER]` block) | none — all container logs |
| resources | `opensearch.resources` / `fluent-bit.resources` | dev-sized defaults |

## Verification status

`helm lint`/`helm template` run clean against `profiles/ok-observability-standard`
on 2026-07-24 (see `implementations/grafana/README.md` for details — same
verification pass covered all four charts). Not yet verified: an actual
`helm install` on a live cluster.

## Usage

```shell
helm dependency update implementations/opensearch
helm template implementations/opensearch \
  -f implementations/opensearch/values.yaml \
  -f <cluster-provider-values.yaml>
```

Consumed as a dependency of `profiles/ok-observability-standard`.
