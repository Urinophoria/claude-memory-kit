#!/usr/bin/env python3
"""atoms-freshness.py — advisory staleness check for the atoms fast-fact layer (memory-sweep T3d).

The atoms layer (memory/atoms.jsonl) is injected into EVERY session on EVERY machine. If a source
memory/<src>.md gains facts but its atoms aren't refreshed, canon injects stale claims fleet-wide
and nothing flags it (sweep high finding: 8/14 sources had moved past their atoms).

For each `src` group, compare the newest atom `date` to the source file's last GIT COMMIT date
(authoritative — mtime is unreliable across clones). Warn only when the source is >2 days newer than
the group's newest atom — the 2-day grace honors atoms.README rule 2 (an atom may trail its source by
a commit). Pure advisory: prints `  ? ...` lines, always exits 0. dr-check [6] calls it.
"""
import json, os, subprocess, sys
from datetime import datetime

# Console-safe markers (cp1252 in cmd/PowerShell can't print ✓/?); reconfigure or fall back to ASCII.
try:
    sys.stdout.reconfigure(encoding="utf-8")
    OK_M, ADV_M = "✓", "?"
except Exception:
    OK_M, ADV_M = "OK", "?"

MEM = os.path.join(os.path.expanduser("~"), "Claude-Memory")
ATOMS = os.path.join(MEM, "memory", "atoms.jsonl")
GRACE_DAYS = 2

def resolve_src(src):
    """An atom's `src` is a memory file basename OR a code-project name. Return the repo-relative
    path of whichever source actually exists, else None."""
    for rel in (f"memory/{src}.md", f"code/{src}/PROJECT.md"):
        if os.path.exists(os.path.join(MEM, *rel.split("/"))):
            return rel
    return None

def commit_date(relpath):
    try:
        out = subprocess.run(["git", "-C", MEM, "log", "-1", "--format=%cs", "--", relpath],
                             capture_output=True, text=True, timeout=10)
        return out.stdout.strip()
    except Exception:
        return ""

def main():
    # Robust read: utf-8-sig tolerates a stray BOM, and a malformed line is SKIPPED (not fatal) —
    # atoms-lint.py is the hard gate that reports corruption; this advisory check must never crash the
    # doctor on a bad line (pass-2 found it did).
    try:
        raw = open(ATOMS, encoding="utf-8-sig").read().splitlines()
    except OSError:
        return
    rows = []
    for l in raw:
        l = l.strip()
        if not l.startswith("{"):
            continue
        try:
            rows.append(json.loads(l))
        except json.JSONDecodeError:
            continue
    groups = {}
    for r in rows:
        s, d = r.get("src"), r.get("date")
        if s and d:
            groups.setdefault(s, []).append(d)
    stale = 0
    for src, dates in sorted(groups.items()):
        newest = max(dates)
        rel = resolve_src(src)
        if rel is None:
            print(f"  ? atoms src '{src}' resolves to no memory/{src}.md nor code/{src}/PROJECT.md — orphaned atom group (fix the src or remove the atoms)")
            stale += 1
            continue
        cd = commit_date(rel)
        if not cd:
            print(f"  {ADV_M} atoms '{src}': {rel} has no git commit date (untracked/uncommitted?) — freshness UNVERIFIED for this group")
            stale += 1
            continue
        try:
            gap = (datetime.fromisoformat(cd).date() - datetime.fromisoformat(newest).date()).days
        except ValueError:
            print(f"  {ADV_M} atoms '{src}': unparseable date (atom {newest} / commit {cd}) — freshness UNVERIFIED")
            stale += 1
            continue
        if gap > GRACE_DAYS:
            print(f"  {ADV_M} atoms '{src}' may be STALE — {rel} last committed {cd}, newest atom {newest} "
                  f"({gap}d gap); re-atomize if that change added facts (advisory, {GRACE_DAYS}d grace)")
            stale += 1
    if stale == 0:
        print(f"  {OK_M} atoms freshness: every group's atoms are within grace of their source")

if __name__ == "__main__":
    main()
    sys.exit(0)
