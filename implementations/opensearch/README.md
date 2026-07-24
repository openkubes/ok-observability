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
| `HTTP_Passwd` (fluent-bit → OpenSearch) | `fluent-bit.config.outputs` | `""` — **REQUIRED**, must equal the value above; fluent-bit cannot authenticate to OpenSearch's Security Plugin otherwise |
| retention / ILM | not yet implemented | see "Known gap" above |
| log exclusions | `fluent-bit.config.outputs` (add a `[FILTER]` block) | none — all container logs |
| resources | `opensearch.resources` / `fluent-bit.resources` | dev-sized defaults |

## Verification status

`helm lint`/`helm template` ran clean on 2026-07-24, but that pass gave a
**false confidence signal** for this chart specifically: a `helm template`
grep for a Service named `ok-observability-opensearch` (the
`fullnameOverride` value) appeared to match, but that match was a
different resource — not the actual Service consumed by fluent-bit.
Running a real `helm install` against `ok-shared` revealed fluent-bit
failing DNS resolution (`getaddrinfo(...): Domain name not found`) against
that assumed name. The real Service, confirmed via `kubectl get svc`, is
**`opensearch-cluster-master`** (+ `opensearch-cluster-master-headless`) —
the opensearch-project/helm-charts chart names its Service from
`clusterName` + node role, not from `fullnameOverride`/the standard Helm
fullname convention. Fixed in `values.yaml` (fluent-bit output `Host`) and
`tests/contract-test.sh` (`OPENSEARCH_SVC` default).

Lesson for this repo: a `helm template` grep match is not sufficient
verification for a chart whose naming doesn't follow the standard Helm
fullname helper — a live install surfaces things a template render can
silently get wrong.

## Known issue, fixed: fluent-bit needs TLS + Basic Auth, not just the right hostname

After fixing the Service name above, fluent-bit still failed to reach
OpenSearch: `broken connection to opensearch-cluster-master:9200` / `HTTP
status=0`. Cause: OpenSearch's Security Plugin (enabled by default — see
the required admin-password Provider Value above) serves **HTTPS** with a
self-signed demo certificate and requires **Basic Auth** even for the Bulk
API fluent-bit posts to; a plaintext HTTP request without credentials
fails at the TLS handshake, not at DNS/routing. Fixed by adding
`tls On`, `tls.verify Off` (self-signed cert — acceptable for the v1
reference profile; revisit if a real CA is introduced), and
`HTTP_User`/`HTTP_Passwd` to `fluent-bit.config.outputs`. `HTTP_Passwd`
must equal `opensearch.extraEnvs[].OPENSEARCH_INITIAL_ADMIN_PASSWORD` —
two separate `--set` values that must be kept in sync manually for now;
a shared Kubernetes Secret referenced by both would be more robust and is
a reasonable follow-up, not attempted here.

## Usage

```shell
helm dependency update implementations/opensearch
helm template implementations/opensearch \
  -f implementations/opensearch/values.yaml \
  -f <cluster-provider-values.yaml>
```

Consumed as a dependency of `profiles/ok-observability-standard`.
