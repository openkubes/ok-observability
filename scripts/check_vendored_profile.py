#!/usr/bin/env python3
"""Fail-closed verification of the standard profile's vendored chart graph."""

from __future__ import annotations

import hashlib
import json
import re
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


def local_helm_version(binary: str) -> str | None:
    """Return the local helm's version, or None if it cannot be determined."""
    try:
        out = subprocess.run(
            [binary, "version", "--short"], capture_output=True, text=True, timeout=60
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r"v?(\d+\.\d+\.\d+)", out)
    return match.group(1) if match else None


def helm_command(render: dict) -> list[str]:
    """Resolve a helm that reproduces the locked render, preferring a local match.

    The locked digest is a property of the rendered output AND of the renderer that
    produced it. Recording only the packages left `main` looking broken to anyone whose
    helm differed, when nothing was wrong with the content -- the checker was simply being
    run by a different program than the one the lock describes.

    So the version is now recorded next to the digest it explains, and the checker obtains
    it rather than demanding the operator install it: an exactly-matching local helm is used
    as-is, otherwise the pinned image is run through a container runtime. The image is
    pinned by digest, because a floating tag would reintroduce the same hole one layer down.
    """
    required = render.get("helmVersion")
    if not required:
        fail("artifact lock does not record offlineRender.helmVersion")

    binary = shutil.which("helm")
    if binary is not None and local_helm_version(binary) == required:
        return [binary]

    image = render.get("helmImage")
    if not image:
        fail("artifact lock does not record offlineRender.helmImage")
    runtime = shutil.which("docker") or shutil.which("podman")
    if runtime is None:
        found = local_helm_version(binary) if binary else None
        fail(
            f"helm {required} is required to reproduce the locked render; "
            f"local helm is {found or 'absent'} and no container runtime was found. "
            f"Install helm {required}, or make docker/podman available to run {image}."
        )

    # Mount the repository read-only at its own path so absolute paths inside the
    # container resolve exactly as they do outside.
    return [
        runtime, "run", "--rm", "-i",
        "-v", f"{ROOT}:{ROOT}:ro",
        "-w", str(ROOT),
        "--entrypoint", "/usr/bin/helm",
        image,
    ]


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

    render = lock.get("offlineRender", {})
    helm = helm_command(render)
    command = [
        *helm,
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
