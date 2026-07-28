#!/usr/bin/env python3
"""check_vso_template — the VSO template must stay equivalent to the proven example.

implementations/vault-secrets-operator/ holds two files that must not drift apart:

  vault-secret-sync.ok-robotics.yaml   the worked example, proven on ok-robotics
  vault-secret-sync.template.yaml      the parameterised form ok-cluster renders

Rendered with ok-robotics' own values, the template must produce *semantically
identical* resources to the example. Otherwise someone edits one file, the other
silently rots, and the divergence only surfaces on a real cluster.

Deliberate limits — this catches drift, not design:

  * It cannot catch an over-collapsed parameterisation. Two distinct fields mapped
    to one variable render identically whenever the values coincide, which is
    exactly how `role` and `serviceAccount` (both `sa-obs`) hid their conflation
    until review. Judging whether two fields are the *same concept* is a reading
    task, not a diff.
  * It asserts nothing about Vault-side state (mounts, roles, policies).

Deterministic and cluster-free, per AGENTS.md §Mandatory verification workflow.
"""
from __future__ import annotations

import re
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

DIR = Path(__file__).resolve().parent.parent / "implementations" / "vault-secrets-operator"
EXAMPLE = DIR / "vault-secret-sync.ok-robotics.yaml"
TEMPLATE = DIR / "vault-secret-sync.template.yaml"

# ok-robotics' own values, so the render must reproduce the example exactly.
VALUES = {
    "CLUSTER": "ok-robotics",
    "OBS_NAMESPACE": "ok-observability",
    "SECRET_NAME": "ok-observability-credentials",
    "VAULT_ADDR": "https://192.168.100.207:443",
    "VAULT_TLS_SERVER_NAME": "vault.ok-shared.internal",
    "VAULT_CA_SECRET": "vault-ca",
    "KV_MOUNT": "secret",
    "KV_PATH": "ok-robotics/obs/observability-credentials",
    "VAULT_ROLE": "sa-obs",
    "VSO_SERVICE_ACCOUNT": "sa-obs",
    "REFRESH_AFTER": "60s",
}


def fail(msg: str) -> None:
    print(f"check-vso-template: FAIL — {msg}", file=sys.stderr)
    sys.exit(1)


def by_id(docs) -> dict:
    return {f"{d['kind']}/{d['metadata']['name']}": d for d in docs if d}


def main() -> None:
    for p in (EXAMPLE, TEMPLATE):
        if not p.is_file():
            fail(f"missing {p.name}")

    raw = TEMPLATE.read_text()

    # Every ${VAR} in the manifest body must be a variable we know how to supply.
    # The header comment is excluded: it legitimately mentions chart-side
    # placeholders such as ${OPENSEARCH_PASSWORD} that must NOT be substituted.
    body = raw.split("# ---------------------------------------------------------------------------", 1)
    if len(body) != 2:
        fail("template header separator missing — cannot separate comment from manifest body")
    used = set(re.findall(r"\$\{([A-Z_][A-Z0-9_]*)\}", body[1]))
    unknown = used - set(VALUES)
    if unknown:
        fail(f"template uses variables this check cannot supply: {sorted(unknown)}")
    unused = set(VALUES) - used
    if unused:
        fail(f"check supplies variables the template no longer uses: {sorted(unused)}")

    if shutil.which("envsubst"):
        # Exercise the documented render path, including the explicit variable list.
        varlist = " ".join(f"${k}" for k in VALUES)
        rendered = subprocess.run(
            ["envsubst", varlist],
            input=raw, capture_output=True, text=True, env={**VALUES, "PATH": "/usr/bin:/bin"},
        )
        if rendered.returncode != 0:
            fail(f"envsubst failed: {rendered.stderr.strip()}")
        out = rendered.stdout
    else:
        print("check-vso-template: envsubst not found — substituting in-process")
        out = raw
        for k, v in VALUES.items():
            out = out.replace(f"${{{k}}}", v)

    manifest = out.split("# ---------------------------------------------------------------------------", 1)[1]
    leftover = re.findall(r"\$\{[A-Z_][A-Z0-9_]*\}", manifest)
    if leftover:
        fail(f"unresolved placeholders after render: {sorted(set(leftover))}")

    try:
        got = by_id(yaml.safe_load_all(manifest))
        want = by_id(yaml.safe_load_all(EXAMPLE.read_text()))
    except yaml.YAMLError as e:
        fail(f"YAML parse error: {e}")

    if set(got) != set(want):
        fail(
            "resource set differs from the proven example\n"
            f"  example : {sorted(want)}\n"
            f"  template: {sorted(got)}"
        )

    for key in sorted(want):
        if got[key] != want[key]:
            diffs = [k for k in set(want[key]) | set(got[key]) if want[key].get(k) != got[key].get(k)]
            fail(
                f"{key} differs from the proven example in: {diffs}\n"
                f"  example : { {k: want[key].get(k) for k in diffs} }\n"
                f"  template: { {k: got[key].get(k) for k in diffs} }"
            )

    print(f"check-vso-template: {len(want)} resource(s) match the proven ok-robotics example")
    print("check-vso-template: PASS (equivalence only — cannot detect an over-collapsed variable)")


if __name__ == "__main__":
    main()
