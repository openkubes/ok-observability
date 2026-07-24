#!/usr/bin/env python3
"""check_charts: structural validation of Helm chart trees under
implementations/ and profiles/.

This is NOT a substitute for `helm lint` / `helm template`. It exists
because no `helm` binary could be installed in the environment these charts
were authored in (network egress to get.helm.sh / api.github.com was
blocked). It catches YAML syntax errors, missing Chart.yaml required
fields, and dependency entries that don't resolve (repository URL present,
or a local file:// path that exists) — nothing more. Run real Helm commands
before merging (see each implementations/*/README.md "Verification status").
"""
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("check-charts: FAIL — PyYAML not installed", file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent
REQUIRED_CHART_FIELDS = ("apiVersion", "name", "version")

failures = []
chart_dirs = sorted(
    {p.parent for p in ROOT.glob("implementations/*/Chart.yaml")}
    | {p.parent for p in ROOT.glob("profiles/*/Chart.yaml")}
)


def load_yaml(path: Path):
    try:
        return yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        failures.append(f"  INVALID YAML {path.relative_to(ROOT)}: {e}")
        return None


print(f"check-charts: {len(chart_dirs)} chart(s) found")

for chart_dir in chart_dirs:
    rel = chart_dir.relative_to(ROOT)
    chart = load_yaml(chart_dir / "Chart.yaml")
    if chart is None:
        continue

    for field in REQUIRED_CHART_FIELDS:
        if not chart.get(field):
            failures.append(f"  {rel}/Chart.yaml missing required field: {field}")

    for dep in chart.get("dependencies", []) or []:
        name = dep.get("name", "<unnamed>")
        repo = dep.get("repository", "")
        version = dep.get("version")
        if not version:
            failures.append(f"  {rel}: dependency '{name}' has no pinned version")
        if repo.startswith("file://"):
            dep_path = (chart_dir / repo[len("file://"):]).resolve()
            if not (dep_path / "Chart.yaml").exists():
                failures.append(
                    f"  {rel}: local dependency '{name}' -> {repo} does not "
                    f"resolve to a chart (expected {dep_path}/Chart.yaml)"
                )
        elif not repo:
            failures.append(f"  {rel}: dependency '{name}' has no repository")

    values_path = chart_dir / "values.yaml"
    if values_path.exists():
        load_yaml(values_path)  # parse-only; records failures via load_yaml

    print(f"  ok   {rel} ({chart.get('name')} {chart.get('version')})")

if failures:
    print("\n".join(failures), file=sys.stderr)
    print("check-charts: FAIL", file=sys.stderr)
    sys.exit(1)
print("check-charts: PASS (structural only — not a substitute for helm lint/template)")
