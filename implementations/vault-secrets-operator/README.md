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

## Per-cluster values to adjust

| Field | ok-robotics value | note |
|---|---|---|
| namespace | `ok-observability` | the stack's namespace |
| `VaultConnection.address` | `https://10.44.0.38:30443` | **interim** NodePort on an ok-shared node IP |
| `VaultConnection.tlsServerName` | `vault.ok-shared.internal` | SNI for cert validation |
| `VaultAuth.mount` | `kubernetes/ok-robotics` | per-cluster auth mount |
| `VaultStaticSecret.path` | `ok-robotics/obs/observability-credentials` | KV path |

## Notes

- **Interim reachability:** child clusters run no MetalLB, so the Traefik LB has no
  external IP — we use the NodePort `30443` + SNI. The canonical fix is a host-level
  LoadBalancer on ok-infra (`ok-mgmt-lb` pattern), after which `address` becomes
  `https://vault.ok-shared.internal:443`. Tracked in OK-110.
- VSO adds a `_raw` key (full KV JSON) to the Secret — harmless; the charts read
  only the named keys.
- `overwrite: true` lets VSO adopt a pre-existing file-based Secret of the same name.
