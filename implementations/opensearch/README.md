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
| retention / ILM | not yet implemented | see "Known gap" above |
| log exclusions | `fluent-bit.config.outputs` (add a `[FILTER]` block) | none — all container logs |
| resources | `opensearch.resources` / `fluent-bit.resources` | dev-sized defaults |

## Verification status

Same caveat as `implementations/grafana`: `helm lint`/`helm template` could
not be run in the authoring environment (no `helm` binary installable — see
`AGENTS.md` / `scripts/check_charts.py` for the structural stand-in used
instead). Run the real Helm commands before merging.

## Usage

```shell
helm dependency update implementations/opensearch
helm template implementations/opensearch \
  -f implementations/opensearch/values.yaml \
  -f <cluster-provider-values.yaml>
```

Consumed as a dependency of `profiles/ok-observability-standard`.
