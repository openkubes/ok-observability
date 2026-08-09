#!/usr/bin/env python3
"""Fail-closed verification of the standard profile's vendored chart graph."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT / "profiles" / "ok-observability-standard"
LOCK = PROFILE / "artifact-lock.json"


def fail(message: str) -> None:
    print(f"VENDORED PROFILE: FAIL — {message}", file=sys.stderr)
    raise SystemExit(1)


def package_metadata(path: Path) -> tuple[str, str]:
    try:
        with tarfile.open(path, "r:gz") as archive:
            chart_members = [
                member for member in archive.getmembers()
                if member.name.count("/") == 1 and member.name.endswith("/Chart.yaml")
            ]
            if len(chart_members) != 1:
                fail(f"{path.name}: expected one root Chart.yaml, found {len(chart_members)}")
            extracted = archive.extractfile(chart_members[0])
            if extracted is None:
                fail(f"{path.name}: cannot read root Chart.yaml")
            lines = extracted.read().decode("utf-8").splitlines()
    except (OSError, tarfile.TarError, UnicodeDecodeError) as exc:
        fail(f"{path.name}: invalid Helm package: {exc}")

    fields: dict[str, str] = {}
    for line in lines:
        if not line.startswith(("name:", "version:")):
            continue
        key, value = line.split(":", 1)
        fields[key] = value.strip().strip('"').strip("'")
    if "name" not in fields or "version" not in fields:
        fail(f"{path.name}: root Chart.yaml lacks name or version")
    return fields["name"], fields["version"]


def main() -> None:
    try:
        lock = json.loads(LOCK.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read {LOCK.relative_to(ROOT)}: {exc}")

    if lock.get("schema") != "openkubes.io/ok-observability-vendored-artifacts/v1":
        fail("unsupported or missing artifact-lock schema")

    packages = lock.get("packages")
    if not isinstance(packages, list) or len(packages) != 3:
        fail("artifact lock must contain exactly three packages")

    required_names = {
        "ok-observability-grafana",
        "ok-observability-opensearch",
        "ok-observability-prometheus",
    }
    names = {item.get("name") for item in packages if isinstance(item, dict)}
    if names != required_names:
        fail(f"package identity set mismatch: {sorted(str(name) for name in names)}")

    for item in packages:
        if not all(isinstance(item.get(field), str) for field in ("path", "sha256", "version")):
            fail(f"invalid package lock entry: {item!r}")
        relative_path = Path(item["path"])
        if relative_path.is_absolute() or ".." in relative_path.parts:
            fail(f"package path must stay within the profile: {item['path']}")

    expected_paths = {PROFILE / item["path"] for item in packages}
    actual_paths = set((PROFILE / "charts").glob("*.tgz"))
    if actual_paths != expected_paths:
        missing = sorted(str(p.relative_to(ROOT)) for p in expected_paths - actual_paths)
        extra = sorted(str(p.relative_to(ROOT)) for p in actual_paths - expected_paths)
        fail(f"package membership mismatch; missing={missing}, extra={extra}")

    for item in packages:
        path = PROFILE / item["path"]
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != item["sha256"]:
            fail(f"{path.name}: sha256 {digest} != locked {item['sha256']}")
        name, version = package_metadata(path)
        if (name, version) != (item["name"], item["version"]):
            fail(
                f"{path.name}: package identity {name}@{version} != "
                f"locked {item['name']}@{item['version']}"
            )

    helm = shutil.which("helm")
    if helm is None:
        fail("helm is required to prove the offline render")
    render = lock.get("offlineRender", {})
    command = [
        helm,
        "template",
        render["release"],
        str(PROFILE),
        "--namespace",
        render["namespace"],
        "--kube-version",
        render["kubernetesVersion"],
    ]
    if render.get("includeCRDs") is True:
        command.append("--include-crds")
    result = subprocess.run(command, check=False, capture_output=True)
    if result.returncode != 0:
        fail(f"offline helm template failed: {result.stderr.decode('utf-8', 'replace').strip()}")
    render_digest = hashlib.sha256(result.stdout).hexdigest()
    if render_digest != render.get("sha256"):
        fail(f"offline render sha256 {render_digest} != locked {render.get('sha256')}")

    print(f"VENDORED PROFILE: PASS — {len(packages)} exact packages")
    print(f"VENDORED PROFILE: PASS — offline render sha256:{render_digest}")


if __name__ == "__main__":
    main()
