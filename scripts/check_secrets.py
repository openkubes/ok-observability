#!/usr/bin/env python3
"""check_secrets: lightweight deterministic secret scan (no external deps).

Not a replacement for gitleaks in CI — a fast local guard against the obvious.
Provider Values and credentials must never live in this repository (AGENTS.md).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

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

for f in sorted(ROOT.rglob("*")):
    if not f.is_file() or SKIP_DIRS & set(f.parts) or f.resolve() == SKIP_SELF:
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
