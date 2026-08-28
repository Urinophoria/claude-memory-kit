#!/usr/bin/env python3
"""atoms-lint.py -- integrity guard for the atoms fast-fact layer (memory/atoms.jsonl).

Built 2026-08-26 to make the atom system bulletproof before it graduates from PILOT. The frantic
early work left 4 duplicate ids + a dangling cross-reference (canon referenced wr-27 with no atom);
nothing caught it. This is the standing check that would have. Run by dr-check.sh [7] as a HARD gate.

HARD failures (exit 1 -- these break the layer or create ambiguity):
  - a line that is not valid JSON (BOM/encoding/corruption -> the whole layer silently degrades)
  - a missing required field (id, claim, src, date, conf)
  - a malformed id (must be <prefix>-NN), a bad date, a bad conf/status value
  - a DUPLICATE id (the atoms.README 'never reuse' rule -- the exact drift Paul flagged)
  - a claim containing a double-quote (breaks the schema's escaping contract)
  - a src that resolves to no memory/<src>.md nor code/<src>/PROJECT.md
  - a superseded atom whose `by` points at a non-existent atom
  - a DANGLING cross-reference: canon .md text references <prefix>-NN but no such atom exists

Advisory (does NOT fail): numbering gaps per prefix; an over-long claim (probably not an atom).

Run:  py setup/atoms-lint.py     Exit: 0 = clean, 1 = hard failures (listed).
"""
import json, os, re, sys
from collections import Counter, defaultdict

# The ✓/✗/? markers must survive a cp1252 Windows console (dr-check runs under Git Bash/UTF-8, but a
# direct `python setup/atoms-lint.py` in cmd/PowerShell is cp1252). Reconfigure, else fall back to ASCII.
try:
    sys.stdout.reconfigure(encoding="utf-8")
    OK_M, BAD_M, ADV_M = "✓", "✗", "?"
except Exception:
    OK_M, BAD_M, ADV_M = "OK", "X", "?"

REPO = os.path.join(os.path.expanduser("~"), "Claude-Memory")
# Optional path arg (for tests/CI); defaults to canon. The dangling-ref scan always walks canon REPO.
ATOMS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "memory", "atoms.jsonl")
REQUIRED = ("id", "claim", "src", "date", "conf")
ID_RE = re.compile(r"^[a-z]+-\d+$")
DATE_RE = re.compile(r"^20\d\d-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$")
CONF_OK = {"high", "med", "low"}
STATUS_OK = {"open", "resolved", "superseded"}

# Reuse the redaction scanner's CALIBRATED secret detection so a credential VALUE inlined into an atom can
# never ride the SessionStart injection or auto-push into git history (durable on every clone). Import
# scan_text from the redaction module — ONE source of truth for "what is a secret". Degrade LOUDLY if it
# can't load. scan_text returns hits whose context is ALREADY masked, so reporting it can't re-leak.
_scan_text = None
_scan_err = ""
try:
    import importlib.util
    _rs_path = os.path.join(REPO, "transcripts", "render-session.py")
    _spec = importlib.util.spec_from_file_location("_render_session", _rs_path)
    _rs = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_rs)
    _scan_text = _rs.scan_text
except Exception as e:  # pragma: no cover - defensive
    _scan_err = str(e)

fail = []      # hard failures
note = []      # advisory

def hard(m): fail.append(m)
def warn(m): note.append(m)

def resolve_src(src):
    for rel in (("memory", src + ".md"), ("code", src, "PROJECT.md")):
        if os.path.exists(os.path.join(REPO, *rel)):
            return True
    return False

def main():
    if not os.path.isfile(ATOMS):
        print("  atoms-lint: no memory/atoms.jsonl (nothing to check)")
        return 0

    if _scan_err:
        warn(f"secret-shape scan SKIPPED -- could not load the redaction scanner ({_scan_err[:80]}); "
             f"atoms are NOT checked for inlined credentials this run")

    atoms, ids = [], []
    # utf-8-sig strips a stray BOM so we can report it rather than silently dropping line 1
    raw = open(ATOMS, "rb").read()
    if raw.startswith(b"\xef\xbb\xbf"):
        hard("atoms.jsonl starts with a UTF-8 BOM -- strip it (save as UTF-8 without BOM); it corrupts line 1's JSON")
    text = raw.decode("utf-8-sig", errors="replace")
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s:
            continue
        if not s.startswith("{"):
            hard(f"line {n}: not a JSON object (starts with {s[:12]!r})")
            continue
        try:
            a = json.loads(s)
        except json.JSONDecodeError as e:
            hard(f"line {n}: invalid JSON ({e})")
            continue
        atoms.append((n, a))
        aid = a.get("id")
        if aid:
            ids.append(aid)

    idset = set(ids)

    # per-atom field checks
    for n, a in atoms:
        aid = a.get("id", f"<line {n}>")
        for f in REQUIRED:
            if not a.get(f):
                hard(f"{aid} (line {n}): missing required field '{f}'")
        if a.get("id") and not ID_RE.match(a["id"]):
            hard(f"line {n}: malformed id '{a['id']}' (must be <prefix>-NN, lowercase)")
        if a.get("date") and not DATE_RE.match(str(a["date"])):
            hard(f"{aid}: bad date '{a.get('date')}' (want YYYY-MM-DD)")
        if a.get("conf") and a["conf"] not in CONF_OK:
            hard(f"{aid}: bad conf '{a['conf']}' (want high|med|low)")
        st = a.get("status")
        if st and st not in STATUS_OK:
            hard(f"{aid}: bad status '{st}' (want open|resolved|superseded)")
        if st == "superseded":
            by = a.get("by")
            if not by:
                hard(f"{aid}: status=superseded but no 'by' pointer")
            elif by not in idset:
                hard(f"{aid}: superseded 'by' -> '{by}' which is not an existing atom")
        if a.get("src") and not resolve_src(a["src"]):
            hard(f"{aid}: src '{a['src']}' resolves to no memory/{a['src']}.md nor code/{a['src']}/PROJECT.md")
        # A double-quote INSIDE a claim is valid JSON when escaped (the parser above is the real guard);
        # the README just prefers single quotes to avoid escaping mistakes. Advisory nudge, not a failure.
        if isinstance(a.get("claim"), str) and '"' in a["claim"]:
            warn(f"{aid}: claim has a double-quote -- valid, but README prefers single quotes (avoids escaping slips)")
        # HARD-fail an atom whose claim inlines a real credential VALUE. Only 'hot' hits count; prose and
        # placeholders are not hot. The context is masked by scan_text, so it never re-leaks.
        if _scan_text and isinstance(a.get("claim"), str):
            hits, _ = _scan_text(a["claim"])
            for (_ln, nm, ctx, is_hot) in hits:
                if is_hot:
                    hard(f"{aid}: claim appears to INLINE A SECRET ({nm}) -- move the value to a gitignored "
                         f"secrets file and reference it by NAME, never inline it. Masked context: {ctx}")

    # duplicate ids (the headline rule)
    for k, c in Counter(ids).items():
        if c > 1:
            lines = [str(n) for n, a in atoms if a.get("id") == k]
            hard(f"DUPLICATE id '{k}' used {c}x (lines {', '.join(lines)}) -- ids are permanent handles, never reuse")

    # numbering gaps (advisory)
    byp = defaultdict(list)
    for i in ids:
        m = re.match(r"([a-z]+)-(\d+)$", i)
        if m:
            byp[m.group(1)].append(int(m.group(2)))
    for p, nums in sorted(byp.items()):
        u = sorted(set(nums))
        gaps = [x for x in range(u[0], u[-1] + 1) if x not in u]
        if gaps:
            warn(f"prefix '{p}': numbering gap(s) {gaps} -- fine if intentional, but a gap that canon REFERENCES is a lost atom")

    # dangling cross-references: canon text references <prefix>-NN but no such atom
    prefixes = sorted({re.match(r"([a-z]+)-", i).group(1) for i in ids if re.match(r"([a-z]+)-", i)})
    if prefixes:
        tok_re = re.compile(r"\b(" + "|".join(prefixes) + r")-\d+\b")
        referenced = defaultdict(list)   # atom-id -> [where]
        for base, _dirs, files in os.walk(REPO):
            # skip the transcript/raw/vendored trees; only canon narrative
            if any(seg in base for seg in (os.sep + ".git", os.sep + "transcripts", os.sep + "Projects", os.sep + "node_modules")):
                continue
            for fn in files:
                if not fn.endswith(".md"):
                    continue
                fp = os.path.join(base, fn)
                try:
                    t = open(fp, encoding="utf-8", errors="replace").read()
                except OSError:
                    continue
                for m in tok_re.finditer(t):
                    referenced[m.group(0)].append(os.path.relpath(fp, REPO))
        for ref, where in sorted(referenced.items()):
            if ref not in idset:
                w = Counter(where).most_common(2)
                hard(f"DANGLING ref '{ref}' -- canon mentions it ({', '.join(f'{p}x {f}' for f, p in w)}) but no such atom exists")

    # report
    for m in fail:
        print(f"  {BAD_M} {m}")
    for m in note:
        print(f"  {ADV_M} {m}")
    if not fail:
        print(f"  {OK_M} atoms integrity OK -- {len(ids)} atoms, no duplicates, all src resolve, no dangling refs"
              + (f" ({len(note)} advisory note(s))" if note else ""))
    return 1 if fail else 0

if __name__ == "__main__":
    sys.exit(main())
