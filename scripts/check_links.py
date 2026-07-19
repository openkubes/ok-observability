#!/usr/bin/env python3
"""check_links: relative markdown links resolve to existing files (deterministic).

External (http/https/mailto) links are ignored — no network access, no flakiness.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")

failures = []
checked = 0

for md in sorted(ROOT.rglob("*.md")):
    if ".git" in md.parts:
        continue
    for target in LINK_RE.findall(md.read_text(encoding="utf-8")):
        if target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        checked += 1
        path = (md.parent / target.split("#")[0]).resolve()
        if not path.exists():
            failures.append(f"  BROKEN {md.relative_to(ROOT)} -> {target}")

print(f"check-links: {checked} relative link(s) checked")
if failures:
    print("\n".join(failures), file=sys.stderr)
    print("check-links: FAIL", file=sys.stderr)
    sys.exit(1)
print("check-links: PASS")
