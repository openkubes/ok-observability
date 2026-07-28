# Vault Secrets Operator — datacenter-envelope Secret profile

Sources the `ok-observability-credentials` Secret from the **central Vault on
ok-shared** via the **Vault Secrets Operator (VSO)** instead of the offline
file-based step in `ok-cluster make install-observability`. This is the
**datacenter-envelope** profile of the Secret Contract (OK-71); edge/air-gapped
clusters keep the offline file profile. Decided in ADR-Platform-025; Vault stood
up in OK-110; this wiring is OK-109 Part 2.

**No chart change.** Grafana (`admin.existingSecret`), OpenSearch (`secretKeyRef`)
and Fluent Bit (`${OPENSEARCH_PASSWORD}`) keep reading the same named Secret with
the same keys (`grafana-admin-user`, `grafana-admin-password`,
`opensearch-admin-password`). Only *who populates the Secret* changes.

## Flow

```
sa-obs token ─► Vault kubernetes/<cluster> login ─► KV read secret/<cluster>/obs/* 
     ▲                                                          │
 (VaultAuth)                                                    ▼
VSO ───────────────────────────────► writes native Secret ok-observability-credentials
```

## Prerequisites (per consuming cluster)

1. **Credentials in Vault** (KV v2 at `secret/`):
   `secret/<cluster>/obs/observability-credentials` with keys
   `grafana-admin-user`, `grafana-admin-password`, `opensearch-admin-password`.
   Seed the values to match the running stack (OpenSearch bakes its admin password
   at first boot — a mismatch locks you out).
2. **Vault auth mount + role/policy** for the cluster, provisioned by the ok-cluster
   `VaultConfig` XR (provider-vault reconciler): mount `kubernetes/<cluster>`, role
   bound to SA `<obs-ns>/sa-obs`, policy read on `secret/data/<cluster>/obs/*`.
3. **SA** `sa-obs` in the observability namespace (VSO's auth identity).
4. **CA secret** `vault-ca` (key `ca.crt`) in the observability namespace = the
   ok-shared internal CA (cert-manager), so VSO trusts the Vault endpoint.
5. **VSO installed** (once per cluster):
   ```bash
   helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
   helm install vault-secrets-operator hashicorp/vault-secrets-operator \
     -n vault-secrets-operator --create-namespace
   ```

## Apply

```bash
kubectl apply -f vault-secret-sync.ok-robotics.yaml
kubectl -n ok-observability get vaultstaticsecret ok-observability-credentials
# expect SYNCED/HEALTHY/READY = True
```

Then re-run the OK-79 contract test gate to confirm the stack is still green with
the Vault-sourced Secret (see `tests/contract-test.sh`).

## Two files: a worked example and a template

| File | Use |
|---|---|
| `vault-secret-sync.ok-robotics.yaml` | the worked example — concrete values, proven on ok-robotics 2026-07-26. Read this first. |
| `vault-secret-sync.template.yaml` | the parameterised form ok-cluster renders and applies per cluster (OK-117). |

ok-cluster **installs** the capability and does not own the asset (ADR-Platform-018 /
ADR-Platform-024), which is why the template lives here rather than in ok-cluster.

Render it by substituting **only the named variables**:

```
envsubst '$CLUSTER $OBS_NAMESPACE $SECRET_NAME $VAULT_ADDR $VAULT_TLS_SERVER_NAME
          $VAULT_CA_SECRET $KV_MOUNT $KV_PATH $VAULT_ROLE $VSO_SERVICE_ACCOUNT $REFRESH_AFTER' \
  < vault-secret-sync.template.yaml | kubectl apply -f -
```

Pass the explicit list. A bare `envsubst` substitutes every `${VAR}` in the input, so
any unrelated placeholder in the file is silently replaced with an empty string —
verified: with a bare invocation `${OPENSEARCH_PASSWORD}` becomes empty, with the list
form it survives intact. The variables are documented in the template header.

**Ordering is the point.** The `VaultStaticSecret` must reach `SYNCED` *before* the
observability Helm release, because OpenSearch 2.12+ refuses to start without the admin
password at first boot. Applying it afterwards demonstrates migration (ADR-025
criterion 6), not fresh-install ordering (criterion 7).

## Per-cluster values to adjust

| Field | ok-robotics value | template variable |
|---|---|---|
| namespace | `ok-observability` | `OBS_NAMESPACE` |
| `VaultConnection.address` | `https://192.168.100.207:443` | `VAULT_ADDR` — stable host-LB IP (ok-shared-ingress, MetalLB on ok-infra) |
| `VaultConnection.tlsServerName` | `vault.ok-shared.internal` | `VAULT_TLS_SERVER_NAME` |
| `VaultAuth.mount` | `kubernetes/ok-robotics` | `kubernetes/${CLUSTER}` |
| `VaultStaticSecret.path` | `ok-robotics/obs/observability-credentials` | `KV_PATH` |
| `VaultAuth.kubernetes.role` | `sa-obs` | `VAULT_ROLE` — the Vault role, distinct from the SA below |
| `VaultAuth.kubernetes.serviceAccount` | `sa-obs` | `VSO_SERVICE_ACCOUNT` — must be the SA bound in `VAULT_ROLE` |

## Notes

- **Reachability (OK-110 Path A):** child clusters run no MetalLB, so Vault is reached
  via the stable host-level LoadBalancer for ok-shared ingress (`ok-shared-ingress`,
  MetalLB on ok-infra) at `192.168.100.207:443` → Traefik NodePort 30443 →
  IngressRouteTCP SNI passthrough → Vault. `tlsServerName` presents the SNI so the
  cert validates against the pinned CA. Path B (native child-cluster LB via Multus
  NAD, letting `vault.ok-shared.internal` resolve to a child-owned LB IP) is OK-57.
- VSO adds a `_raw` key (full KV JSON) to the Secret — harmless; the charts read
  only the named keys.
- `overwrite: true` lets VSO adopt a pre-existing file-based Secret of the same name.
