#!/usr/bin/env python3
"""check_secrets: lightweight deterministic secret scan (no external deps).

Not a replacement for gitleaks in CI — a fast local guard against the obvious.
Provider Values and credentials must never live in this repository (AGENTS.md).
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def git_ignored(paths):
    """Return the subset of `paths` that git ignores.

    The purpose of this check is to stop secrets from being *committed*.
    Git-ignored files can never be committed, so scanning them only produces
    false positives (e.g. a developer's local `*.provider-values.yaml`, which
    .gitignore explicitly anticipates). We ask git itself rather than
    re-implementing .gitignore matching.

    Fail-safe: if git is unavailable or this is not a git work tree, return an
    empty set so EVERYTHING is scanned (preserves the guard in CI / fresh
    checkouts / tarballs).
    """
    if not paths:
        return set()
    try:
        proc = subprocess.run(
            ["git", "check-ignore", "--stdin"],
            input="\n".join(str(p) for p in paths),
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
    except (FileNotFoundError, OSError):
        return set()  # no git binary -> scan everything
    # 0 = some paths ignored, 1 = none ignored; anything else (e.g. 128 "not a
    # git repository") -> fail safe and scan everything.
    if proc.returncode not in (0, 1):
        return set()
    return {ROOT / line for line in proc.stdout.splitlines() if line}

PATTERNS = [
    ("AWS access key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("Private key block", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("GitHub token", re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}")),
    ("Slack token", re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}")),
    ("Bearer token literal", re.compile(r"(?i)authorization:\s*bearer\s+[a-z0-9._\-]{20,}")),
    ("Password assignment", re.compile(r"(?i)\b(password|passwd|adminPassword)\s*[:=]\s*['\"][^'\"\s]{6,}['\"]")),
]

SKIP_DIRS = {".git"}
SKIP_SELF = Path(__file__).resolve()

findings = []
scanned = 0

candidates = [
    f for f in sorted(ROOT.rglob("*"))
    if f.is_file() and not (SKIP_DIRS & set(f.parts)) and f.resolve() != SKIP_SELF
]
ignored = git_ignored(candidates)

for f in candidates:
    if f in ignored:
        continue
    try:
        text = f.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue
    scanned += 1
    for name, rx in PATTERNS:
        for m in rx.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            findings.append(f"  FOUND {name}: {f.relative_to(ROOT)}:{line}")

print(f"check-secrets: {scanned} file(s) scanned")
if findings:
    print("\n".join(findings), file=sys.stderr)
    print("check-secrets: FAIL", file=sys.stderr)
    sys.exit(1)
print("check-secrets: PASS")
