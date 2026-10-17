#!/usr/bin/env python3
"""drift-test.py — regression guard for render-session.py's selective DRIFT.

Locks in the line drift draws: a raw transcript is a RECORD OF WORK and may drift to the narrower archive
unless record CONTENT entered Claude's context (Read/Grep under a data root, a content-reading verb on a
root, a connector that returns records, a record-system URL/API). Listing, moving or inventorying a root,
running a pipeline over it, and BUILDING the tooling all drift.

Runs entirely in a temp dir against a built-in EXAMPLE policy (TEST_POLICY below, the same rule types your
transcripts/drift-policy.txt uses), so it tests the mechanism whatever your own policy says. It also checks
that your real drift-policy.txt parses.
Run:  py -3 transcripts/drift-test.py     Exit 0 = all pass, 1 = a case regressed.
"""
import argparse, gzip, importlib.util, json, shutil, sys, tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("rs", HERE / "render-session.py")
rs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rs)

TEST_POLICY = r"""
settle 12
root C:\Records-Export
root C:\Records-Convert
root C:\Records-Archive
reader \b(cat|more|less|head|tail|strings|xxd|grep|egrep|rg|findstr|sed|awk)\b
reader \b(Get-Content|gc|Select-String|sls|Import-Csv|Format-Hex)\b
workfile \\_manifest(\\|$)
workfile \.(log|md5|sha256|done)$
tool __(outlook_[a-z_]+|sharepoint_[a-z_]+)$
match https?://\S*records\.example\.com
"""

NOW = datetime.now(timezone.utc)
OLD = (NOW - timedelta(days=2)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
NEW = (NOW - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%S.000Z")

def tool(name, inp, ts=OLD):
    return {"type": "assistant", "timestamp": ts,
            "message": {"role": "assistant", "content": [{"type": "tool_use", "name": name, "input": inp}]}}

def text(role, s, ts=OLD):
    return {"type": role, "timestamp": ts, "message": {"role": role, "content": [{"type": "text", "text": s}]}}

# (session-id8, records, expected decision, reason substring)
CASES = [
    ("a0000001", [tool("Bash", {"command": "git status && git log -3"}), tool("Edit", {"file_path": "memory/x.md"})],
     "drift", "work record only"),
    # READING a record puts content in Claude's context -> hold.
    ("a0000002", [tool("Read", {"file_path": "C:\\Records-Convert\\Prod\\A\\00-source\\msg.eml"})], "hold", "records-convert"),
    # Listing / inventorying / running a pipeline over a root is a RECORD OF WORK -> drift.
    ("a0000003", [tool("Bash", {"command": "ls /c/Records-Archive/roster"})], "drift", "work record only"),
    ("a0000004", [tool("PowerShell", {"command": "Get-ChildItem C:/Records-Archive -Recurse"})], "drift", "work record only"),
    ("a0000005", [tool("Bash", {"command": "py run.py --corpus 'C:\\\\Records-Export\\\\ProdA'"})], "drift", "work record only"),
    # A connector that returns records -> hold; one the policy doesn't name -> drift.
    ("a0000006", [tool("mcp__1111aaaa-0000-4000-8000-000000000001__outlook_email_search", {"query": "budget"})],
     "hold", "tool:"),
    ("a0000007", [tool("mcp__2222bbbb-0000-4000-8000-000000000002__search_threads", {"query": "car parts"})],
     "drift", "work record only"),
    # Starting a job that names no root is work.
    ("a0000008", [tool("PowerShell", {"command": "Start-Job -Name export1 -ScriptBlock { 1 }"})],
     "drift", "work record only"),
    ("a0000009", [tool("Bash", {"command": "git status"}, ts=NEW)], "wait", "settle"),
    ("a000000a", [tool("Bash", {"command": "git status"})], "hold", "policy: hold"),          # explicit hold
    ("a000000b", [tool("Read", {"file_path": "C:\\Records-Export\\x.csv"})], "drift", "policy: drift"),  # explicit drift
    ("a000000c", [text("user", "where do the C:\\Records-Export files go?"),
                  text("assistant", "They live under C:\\Records-Export\\ProdA."), tool("Bash", {"command": "echo hi"})],
     "drift", "work record only"),                                  # TALKING about a root is not processing it
    ("a000000d", [tool("Edit", {"file_path": "C:\\Users\\me\\Claude-Memory\\Projects\\records-tool\\engine.py",
                               "old_string": "a", "new_string": "b"})],
     "drift", "work record only"),                                  # BUILDING the tooling is mechanical
    ("a000000e", [tool("mcp__Claude_Browser__navigate", {"url": "https://portal.records.example.com/cases"})],
     "hold", "match:"),
    # WRITING about a root / GREPPING canon for it is not touching it ...
    ("a000000f", [tool("Write", {"file_path": "transcripts/drift-policy.txt", "content": "root C:\\Records-Export\n"}),
                  tool("Grep", {"pattern": "C:\\\\Records-Export", "path": "memory"})],
     "drift", "work record only"),
    # ... nor is writing Claude's OWN text INTO one (a script, a note): no record content involved ...
    ("a0000010", [tool("Write", {"file_path": "C:\\Records-Convert\\output\\notes.txt", "content": "x"})],
     "drift", "work record only"),
    # ... but GREPPING INSIDE one prints matching record lines: content -> hold.
    ("a0000011", [tool("Grep", {"pattern": "smith", "path": "C:/Records-Export/ProdA"})], "hold", "records-export"),
    # Shell commands: a root + a content-reading verb = record content on screen -> hold.
    ("a0000012", [tool("Bash", {"command": "cat /c/Records-Export/ProdA/msg-0001.eml"})], "hold", "read:"),
    ("a0000013", [tool("PowerShell", {"command": "Import-Csv C:\\Records-Archive\\roster\\roster.csv | Select -First 5"})],
     "hold", "read:"),
    ("a0000014", [tool("PowerShell", {"command": "Get-Content C:/Records-Convert/Prod/A/msgs/0001.txt -Tail 20"})],
     "hold", "read:"),
    # ... but a pipeline's OWN telemetry under a root is a work record:
    ("a0000016", [tool("PowerShell", {"command": "$m='C:\\Records-Convert\\Prod\\A\\_manifest'; Get-Content \"$m\\run.log\" -Tail 45; (Import-Csv \"$m\\stage1-index.csv\").Count"}),
                  tool("Read", {"file_path": "C:\\Records-Convert\\Prod\\A\\_manifest\\watchdog-run-20260902.log"})],
     "drift", "work record only"),
    # ... and so are zip integrity checks (Add-Type is not `type`; .Open() for hashing is not a read):
    ("a0000017", [tool("PowerShell", {"command": "Add-Type -AssemblyName System.IO.Compression.FileSystem; $z=[IO.Compression.ZipFile]::OpenRead('C:\\Records-Export\\ProdA\\x.zip'); foreach($e in $z.Entries){ $s=$e.Open(); (Get-FileHash -InputStream $s).Hash }"})],
     "drift", "work record only"),
    # Moving / inventorying a root during a rebuild is work -> drift.
    ("a0000015", [tool("PowerShell", {"command": "if(Test-Path C:\\Records-Export){Get-ChildItem C:\\Records-Export -Recurse -Filter *.pst}"}),
                  tool("PowerShell", {"command": "robocopy C:\\Records-Export D:\\Records-Export /E /MT:8"})],
     "drift", "work record only"),
]

fails = 0
def check(ok, label):
    global fails
    print(("  ok   " if ok else "  FAIL ") + label)
    fails += 0 if ok else 1

print("== your transcripts/drift-policy.txt parses")
try:
    real = rs.load_drift_policy(HERE / "drift-policy.txt")
    check(True, f"{len(real['root'])} root(s), {len(real['tool'])} tool rule(s), {len(real['match'])} match rule(s), "
                f"settle {real['settle']:g}h")
except Exception as exc:  # a bad regex or a non-numeric settle
    check(False, f"drift-policy.txt does not parse: {exc}")

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    raw, nas = tmp / "raw", tmp / "nas"
    raw.mkdir(); nas.mkdir()
    pol_file = tmp / "drift-policy.txt"
    pol_file.write_text(TEST_POLICY + "\nhold a000000a  # explicit hold\ndrift a000000b  # explicit drift\n",
                        encoding="utf-8")
    pol = rs.load_drift_policy(pol_file)
    for sid, recs, _, _ in CASES:
        with gzip.open(raw / f"2026-09-28-case.{sid}.jsonl.gz", "wt", encoding="utf-8") as fh:
            for r in recs:
                fh.write(json.dumps(r) + "\n")

    print("== classify (example policy + two override lines)")
    got = {rs._session_id8(f.name): (d, r) for f, d, r in rs.classify_dir(raw, pol)}
    for sid, _, want, why in CASES:
        d, r = got[sid]
        check(d == want and why in r, f"{sid}: {d:5} ({r})  want {want}/{why}")

    print("== drift end to end (temp raw -> temp target)")
    rs.DRIFT_RAW, rs.DRIFT_POLICY, rs.DRIFT_STATE = raw, pol_file, tmp / ".drift-state.json"
    held_name = "2026-09-28-case.a0000002.jsonl.gz"
    (nas / "raw").mkdir()
    shutil.copy2(raw / held_name, nas / "raw" / held_name)          # a HELD session already sitting on the target
    from io import StringIO
    buf, real_out = StringIO(), sys.stdout
    sys.stdout = buf
    try:
        rs.cmd_drift(argparse.Namespace(target=str(nas), quiet=False))
    finally:
        sys.stdout = real_out
    out = buf.getvalue()
    on_nas = {rs._session_id8(p.name) for p in (nas / "raw").glob("*.gz")}
    want_drift = {sid for sid, _, w, _ in CASES if w == "drift"}
    check(want_drift <= on_nas, f"every drift-class session landed ({len(want_drift)})")
    check(not ({sid for sid, _, w, _ in CASES if w in ("hold", "wait")} - {"a0000002"}) & on_nas,
          "no held or settling session was copied")
    check("HELD BUT ON TARGET" in out and held_name in out, "a held session already on the target is REPORTED")
    check((nas / "raw" / held_name).exists(), "...and NOT deleted (you remove it)")
    check(f"{len(want_drift)} drifted" in out, "summary counts the drift")
    cache = json.loads((tmp / ".drift-state.json").read_text(encoding="utf-8"))
    check(len(cache) == sum(1 for _, _, w, _ in CASES if w in ("hold", "drift")), "verdicts cached (wait is not)")

    print("== a policy edit re-classifies cached sessions")
    pol_file.write_text(pol_file.read_text(encoding="utf-8") + "hold a0000001  # changed my mind\n",
                        encoding="utf-8")
    pol2 = rs.load_drift_policy(pol_file)
    cache2 = json.loads((tmp / ".drift-state.json").read_text(encoding="utf-8"))
    got2 = {rs._session_id8(f.name): d for f, d, _ in rs.classify_dir(raw, pol2, cache2)}
    check(got2["a0000001"] == "hold", "a0000001 flips to hold despite its cached 'drift'")

print(f"\n{'ALL PASS' if not fails else f'{fails} FAILED'}")
sys.exit(1 if fails else 0)
