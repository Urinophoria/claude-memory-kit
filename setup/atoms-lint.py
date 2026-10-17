#!/usr/bin/env python3
"""atoms-lint.py -- integrity guard for the atoms fast-fact layer (memory/atoms.jsonl).

Built 2026-08-26 to make the atom system bulletproof before it graduates from PILOT. The frantic
early work left 4 duplicate ids + a dangling cross-reference (canon referenced wr-27 with no atom);
nothing caught it. This is the standing check that would have. It GATES both save paths (the
session-autosave Stop hook holds back what fails; canon-save refuses the whole save); dr-check [7]
runs it as an ADVISORY tier (F-B: it never flips the lossless verdict).

HARD failures (exit 1 -- these break the layer or create ambiguity):
  - a line that is not valid JSON (BOM/encoding/corruption -> the whole layer silently degrades)
  - a missing required field (id, claim, src, date, conf)
  - a malformed id (must be <prefix>-NN), a bad date, a bad conf/status value
  - a DUPLICATE id (the atoms.README 'never reuse' rule -- the exact drift that prompted this lint)
  - a claim containing a double-quote (breaks the schema's escaping contract)
  - a src that resolves to no memory/<src>.md nor code/<src>/PROJECT.md
  - a superseded atom whose `by` points at a non-existent atom
  - a DANGLING cross-reference: canon .md text references <prefix>-NN but no such atom exists
  - the BOOT tier over budget: 'boot'-tagged claims > 5,000 chars total, or a superseded atom tagged 'boot'

Advisory (does NOT fail): numbering gaps per prefix; an over-long claim (probably not an atom); a boot
claim over 700 chars.

Run:  py setup/atoms-lint.py     Exit: 0 = clean, 1 = hard failures (listed).
      py setup/atoms-lint.py [--root DIR] [--implicated FILE] [ATOMS_JSONL]
        --root        lint a tree other than ~/Claude-Memory (session-autosave passes an export of the
                      STAGED index, so it lints exactly what it is about to commit, not the working tree)
        --implicated  write the repo-relative paths the HARD failures implicate, one per line (empty =
                      clean) so session-autosave can hold back just those files. Absent after a crash.
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

_args, _opts = sys.argv[1:], {}
while len(_args) > 1 and _args[0] in ("--root", "--implicated"):
    _opts[_args[0]] = _args[1]
    _args = _args[2:]
REPO = _opts.get("--root") or os.path.join(os.path.expanduser("~"), "Claude-Memory")
IMPLICATED_OUT = _opts.get("--implicated")
# Optional path arg (for tests/CI); defaults to canon. The dangling-ref scan always walks REPO.
ATOMS = _args[0] if _args else os.path.join(REPO, "memory", "atoms.jsonl")
try:
    ATOMS_REL = os.path.relpath(ATOMS, REPO).replace(os.sep, "/")
except ValueError:  # different drive on Windows
    ATOMS_REL = ATOMS
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
implicated = set()   # repo-relative paths the hard failures point at (--implicated)

def hard(m, *paths):
    """A HARD failure. `paths` = the files whose content causes it; default = the atoms file itself."""
    fail.append(m)
    implicated.update(paths or (ATOMS_REL,))
def warn(m): note.append(m)

def resolve_src(src):
    for rel in (("memory", src + ".md"), ("code", src, "PROJECT.md")):
        if os.path.exists(os.path.join(REPO, *rel)):
            return True
    return False

# --- src-CONTAINMENT (provenance drift) ----------------------------------------------------------
# The src check above only proves the file EXISTS. An atom is a distilled POINTER; if its source file never
# contained the fact, the pointer is broken (provenance decay). This heuristic flags an atom that shares
# almost NONE of its distinctive terms with its source. ADVISORY only: a distillation never matches its
# source verbatim, so a hard-fail would false-positive and (via the session-autosave gate) block legit
# commits. Deliberately conservative — flags only when an atom has >= MIN_TERMS distinctive terms AND under
# THRESHOLD of them appear in the source.
_STOP = frozenset("""
the a an and or of to in on at for with from by is are was were be been being it its this that these those
you your we our they them he she his her not no yes as if then than so but out up off over under into onto
session memory atom atoms fact status src open resolved when where what which who how why user
new now here there also only just still per via etc use used uses using make made makes set sets get gets
run runs ran one two all any each both same next need needs first last work works project file files
""".split())
_TERM_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_./\-]{2,}")
CONTAIN_MIN_TERMS = 4     # need enough distinctive terms to judge
CONTAIN_THRESHOLD = 0.30  # flag if under 30% of them appear in the source
_src_cache = {}

def distinctive_terms(claim):
    """Specific, searchable tokens from a claim — identifiers, paths, versions, proper nouns — not prose."""
    terms = set()
    for tok in _TERM_RE.findall(claim):
        t = tok.strip("._-/")
        low = t.lower()
        if len(t) < 4 or low in _STOP:
            continue
        has_digit = any(c.isdigit() for c in t)
        has_sep = any(c in "_./" for c in t)
        internal_caps = any(c.isupper() for c in t[1:])
        allcaps = t.isupper() and len(t) >= 3
        cap_word = t[0].isupper() and len(t) >= 5
        if has_digit or has_sep or internal_caps or allcaps or cap_word:
            terms.add(low)
    return terms

def src_text(src):
    if src not in _src_cache:
        _src_cache[src] = None
        for rel in (("memory", src + ".md"), ("code", src, "PROJECT.md")):
            p = os.path.join(REPO, *rel)
            if os.path.exists(p):
                try:
                    _src_cache[src] = open(p, encoding="utf-8", errors="replace").read().lower()
                except OSError:
                    pass
                break
    return _src_cache[src]

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
            # Implicates the src PATHS (a staged delete/rename of the source .md is the fix-side to hold
            # back); a new atom with a typo'd src is caught by autosave's atoms.jsonl last resort.
            hard(f"{aid}: src '{a['src']}' resolves to no memory/{a['src']}.md nor code/{a['src']}/PROJECT.md",
                 f"memory/{a['src']}.md", f"code/{a['src']}/PROJECT.md")
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

    # Boot-tier budget. Atoms tagged 'boot' render IN FULL in the SessionStart hook, whose
    # additionalContext Claude Code caps at 10,000 chars -- past it the model gets a file path + a 2 KB
    # preview and the whole layer goes unseen. The header, index and newest-gists take ~4K of that, so
    # the boot claims get BOOT_CLAIM_BUDGET. Boot is a curated core, not a dumping ground: the
    # per-prompt recall hook surfaces everything else when it is relevant.
    BOOT_CLAIM_BUDGET, BOOT_CLAIM_WARN = 5000, 700
    boot = [(n, a) for n, a in atoms if "boot" in (a.get("tags") or [])]
    boot_chars = sum(len(a.get("claim") or "") for _, a in boot)
    if boot_chars > BOOT_CLAIM_BUDGET:
        hard(f"BOOT tier is {boot_chars} chars across {len(boot)} 'boot'-tagged atoms -- over the {BOOT_CLAIM_BUDGET} "
             f"budget; untag or tighten some (the SessionStart hook is hard-capped at 10,000 chars)")
    for n, a in boot:
        aid = a.get("id", f"<line {n}>")
        if a.get("status") == "superseded":
            hard(f"{aid}: tagged 'boot' but superseded -- untag it (the boot tier must be live facts)")
        elif len(a.get("claim") or "") > BOOT_CLAIM_WARN:
            warn(f"{aid}: boot atom is {len(a['claim'])} chars (> {BOOT_CLAIM_WARN}) -- boot claims should be tight")

    # src-containment advisory (provenance drift — see distinctive_terms/src_text above)
    for n, a in atoms:
        src = a.get("src"); claim = a.get("claim"); aid = a.get("id", f"<line {n}>")
        if not (src and isinstance(claim, str)) or a.get("status") == "superseded":
            continue
        terms = distinctive_terms(claim)
        if len(terms) < CONTAIN_MIN_TERMS:
            continue
        txt = src_text(src)
        if not txt:
            continue
        hit = sum(1 for t in terms if t in txt)
        if hit / len(terms) < CONTAIN_THRESHOLD:
            warn(f"{aid}: src '{src}' resolves but holds only {hit}/{len(terms)} of the atom's distinctive terms "
                 f"— likely PROVENANCE drift (fact not written into its source). Re-point src, or backfill the source.")

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
            # skip the transcript/raw/vendored trees; only canon narrative. .claude/worktrees holds OTHER
            # branches' checkouts (git-excluded, not canon): a sibling session's unmerged ref to its own new
            # atom would read as DANGLING here and falsely block canon-save's lint gate (2026-09-30).
            # Matched against the path RELATIVE to REPO (was the absolute path), so a --root snapshot that
            # lives under .git/ -- or a HOME that happens to contain one of these names -- isn't skipped whole.
            rel = os.sep + os.path.relpath(base, REPO)
            if any(seg in rel for seg in (os.sep + ".git", os.sep + "transcripts", os.sep + "Projects", os.sep + "node_modules",
                                          os.sep + os.path.join(".claude", "worktrees"))):
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
                    # '/' on every OS: these paths feed --implicated (git-style) and the check-canon marker,
                    # whose quote-stripping `tr` would eat a Windows '\' (memory\x.md -> memoryx.md).
                    referenced[m.group(0)].append(os.path.relpath(fp, REPO).replace(os.sep, "/"))
        for ref, where in sorted(referenced.items()):
            if ref not in idset:
                w = Counter(where).most_common(2)
                hard(f"DANGLING ref '{ref}' -- canon mentions it ({', '.join(f'{p}x {f}' for f, p in w)}) but no such atom exists",
                     *set(where))

    # report
    for m in fail:
        print(f"  {BAD_M} {m}")
    for m in note:
        print(f"  {ADV_M} {m}")
    if not fail:
        print(f"  {OK_M} atoms integrity OK -- {len(ids)} atoms, no duplicates, all src resolve, no dangling refs"
              + (f" ({len(note)} advisory note(s))" if note else ""))
    if IMPLICATED_OUT:
        with open(IMPLICATED_OUT, "w", encoding="utf-8", newline="\n") as fh:
            fh.writelines(p + "\n" for p in sorted(implicated))
    return 1 if fail else 0

if __name__ == "__main__":
    sys.exit(main())
