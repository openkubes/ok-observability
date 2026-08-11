# Standard Profile Source Provenance

Status: source amendment; no deployment authorization

The standard profile's three wrapper packages are committed as authoritative
source artifacts. Together they close the transitive Helm dependency graph used
by the profile:

| Wrapper package | Included upstream graph |
| --- | --- |
| `ok-observability-prometheus-0.1.0.tgz` | `kube-prometheus-stack` 62.7.0 and its packaged dependencies |
| `ok-observability-grafana-0.1.0.tgz` | `grafana` 8.6.4 |
| `ok-observability-opensearch-0.1.0.tgz` | `opensearch` 2.30.1 and `fluent-bit` 0.48.6 |

`artifact-lock.json` is the machine-readable authority for exact package
membership and SHA-256 identity. `scripts/check_vendored_profile.py` rejects a
missing, additional, renamed, re-versioned, or byte-different package and then
proves that Helm can render the profile without dependency resolution.

The locked render digest is a property of the rendered output **and** of the Helm
that produced it, so `offlineRender` records `helmVersion` and a digest-pinned
`helmImage` beside it. The checker obtains that Helm rather than requiring it to
be installed: a local Helm reporting the recorded version is used as-is,
otherwise the pinned image runs under docker or podman. Before this, the version
lived only in the prose below, and anyone whose Helm differed saw the check fail
as though the vendored content had changed when it had not.

## OK-141 equivalence evidence

The vendored profile was rendered with Helm v3.20.2, Kubernetes version 1.36.2,
release `disposable-ok141-observability-core`, namespace `ok-observability`,
CRDs included, and the Phase-R-v3 synthetic Provider Values fixture whose
SHA-256 is:

```text
5bb830e4c9adf1a99c180e8af5e8abf609cd3c5754d1d206d0a828e940546fa0
```

The resulting manifest stream is byte-identical to the earlier M0b candidate
render:

```text
sha256:2adb637ca1b4bfd528abc660c102019057cdad5389b989ea1a2d7a5e9c5b7ecf
```

This proves source closure and semantic render equivalence for the bound test
inputs. It does not prove signer authenticity, authorize GitOps registration,
grant M0b or GO-1, or authorize any infrastructure mutation.

## Update rule

Any wrapper byte, version, membership, or render-semantic change requires all
of the following in one reviewed change:

1. regenerate the affected wrapper package from reviewed source dependencies;
2. update `artifact-lock.json` with the new package and render identities;
3. run `make verify`, `helm lint`, and the applicable cross-repository render;
4. regenerate downstream OpenKubes `P`, `R`, execution fixture, and protocol
   identities rather than reinterpreting an existing digest.
