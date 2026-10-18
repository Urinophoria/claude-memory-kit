"""
render-session.py — turn Claude Code session transcripts (.jsonl) into readable Markdown.

Run as `py render-session.py ...` on Windows, `python3 render-session.py ...` on Linux.
(No shebang on purpose: the Windows `py` launcher would follow it to the Microsoft Store
python3 stub and fail.)

Claude Code stores every session verbatim under:
    %USERPROFILE%\\.claude\\projects\\<project-slug>\\<session-id>.jsonl

Those files are the durable record of a conversation, but they're line-delimited JSON
with base64 images and tool payloads inline — not something you'd ever read. This turns
one (or all) of them into Markdown you can actually open.

Two things worth knowing about the output modes:

  conversation (default)  Only what the user and Claude *said*. Tool calls collapse to a
                          one-line summary; tool RESULTS are dropped entirely. This is
                          the low-risk subset — secrets and FERPA material live in tool
                          results and file reads, not in the dialogue.

  full                    Adds thinking blocks and truncated tool results. Higher
                          fidelity, and correspondingly NOT safe to commit unreviewed.

Usage:
    py render-session.py index [--project SLUG]
    py render-session.py render <session-id|path> [-o OUT.md] [--full] [--thinking] [--tool-results]
    py render-session.py render --all [-o OUTDIR] [--project SLUG]
    py render-session.py scan <file-or-dir>

See README.md in this folder for the backup/commit policy.
"""

import argparse
import bisect
import gzip
import hashlib
import json
import os
import re
import shutil
import sys
from datetime import datetime
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

PROJECTS_ROOT = Path(os.environ.get("USERPROFILE", Path.home())) / ".claude" / "projects"

def _default_project_slug():
    """Claude Code slugifies the project cwd (C:\\Users\\me\\Claude-Memory -> C--Users-me-Claude-Memory).
    Derive it from THIS machine's home path rather than hardcoding a name. The autosave hook uses
    `--project ALL` anyway; this is just the default for manual `render` calls."""
    repo = Path(os.environ.get("USERPROFILE", Path.home())) / "Claude-Memory"
    return re.sub(r"[:\\/]+", "-", str(repo)).strip("-")

DEFAULT_PROJECT = _default_project_slug()

# Wrappers the harness injects into the user turn. None of these are the user talking.
NOISE_TAGS = (
    "system-reminder",
    "command-name",
    "command-message",
    "command-args",
    "local-command-stdout",
    "local-command-stderr",
    "user-prompt-submit-hook",
    "task-notification",
)
NOISE_RE = re.compile(
    r"<(" + "|".join(NOISE_TAGS) + r")>.*?</\1>", re.DOTALL | re.IGNORECASE
)
OPEN_TAG_RE = re.compile(r"</?(" + "|".join(NOISE_TAGS) + r")>", re.IGNORECASE)

# (name, regex, group holding the secret VALUE, always-redact?)
# always=False means "report it, but only redact if the value looks high-entropy" —
# that keeps prose like "Password: entered ✓" readable while still catching real ones.
SECRET_PATTERNS = [
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), 0, True),
    # 2026-10-12: FortiOS reversible 'ENC <base64>' config secrets (passphrase/psksecret/password lines in `show`
    # output) and live IPsec SA keys from `get vpn ipsec tunnel name` ("enc:  aes-cb  <hex>", "auth: sha256 <hex>").
    ("fortios-enc", re.compile(r"\bENC\s+([A-Za-z0-9+/=]{16,})"), 1, True),
    ("ipsec-sa-key", re.compile(r"\b(?:enc|auth):\s+[\w-]+\s+([0-9a-fA-F]{32,})"), 1, True),
    ("aws-key", re.compile(r"\bAKIA[0-9A-Z]{16}\b"), 0, True),
    ("bearer", re.compile(r"\bBearer\s+([A-Za-z0-9\-._~+/]{20,})"), 1, True),
    ("gh-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"), 0, True),
    # Branded high-value tokens — ALWAYS redact, never depend on the entropy gate. Added 2026-08-26
    # after pass-2 found the T2 _HEXISH/_IDENTISH exclusions were leaking these (they're 0x-free but
    # underscore-joined, so the old snake_case exclusion voided them).
    ("gh-fine-pat", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"), 0, True),
    ("stripe-key", re.compile(r"\b[sprk]k_(?:live|test)_[A-Za-z0-9]{10,}\b"), 0, True),
    ("gitlab-pat", re.compile(r"\bglpat-[A-Za-z0-9_-]{16,}\b"), 0, True),
    ("slack-token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"), 0, True),
    ("google-key", re.compile(r"\bAIza[A-Za-z0-9_-]{30,}\b"), 0, True),
    ("conn-string", re.compile(r"://[^\s:/@]+:([^\s:/@]{4,})@"), 1, True),
    ("assignment", re.compile(
        # "pass"/"pw" added 2026-10-06: a chat-pasted "user: X  Pass: <value>" slipped every label here.
        # The value is NOT consumed: a consuming group swallowed a label nested in the value
        # ('first pass: password="..."'), so the inner, stronger label was never judged. Now finditer
        # resumes right after the separator and judges every nested assignment on its own. The value is
        # the rest of the whitespace-free run, LOOKED UP by scan_text ("run") rather than matched by a
        # lookahead: a `(?=(\S{6,}))` re-read the whole run at every label, quadratic on a long run.
        r"\b(?:password|passwd|pwd|pass|pw|api[_-]?key|apikey|secret|token|client[_-]?secret)"
        r"\s*[:=]\s*(?=\S{6})", re.IGNORECASE), "run", False),
    ("pfx", re.compile(r"\bpfx[_-]?(?:pw|password)\b", re.IGNORECASE), None, False),
]

# Words that follow "password:" in ordinary prose — never treat these as values.
PROSE_VALUES = {
    "entered", "filled", "correct", "confirmed", "set", "changed", "required",
    "yes", "no", "ok", "done", "blank", "empty", "unknown", "redacted", "hidden",
    "<pfx_pw>", "[redacted]", "***", "________",
}


# A value that is entirely hexadecimal (optionally 0x-/@-prefixed) — a metadata token, address,
# SHA, or RID, not a human credential. Used to spare debug transcripts from over-redaction.
_HEXISH = re.compile(r"(?:0x|@)?[0-9a-fA-F]+", re.IGNORECASE)
# An ALL-CAPS SCREAMING_SNAKE identifier — a constant or env-var NAME (HTTP_CSRF_TOKEN,
# API_KEY_HEADER), not a secret VALUE; spares "token: `SOME_CONSTANT`"-style prose. Deliberately
# ALL-CAPS only (2026-08-26 pass-2 fix): the old mixed-case rule also excused real underscore-joined
# passwords like `Winter_2026_Portal_Login` and lowercase branded tokens like `github_pat_…`.
_IDENTISH = re.compile(r"[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+")


def _class_count(v):
    return sum([
        any(c.islower() for c in v),
        any(c.isupper() for c in v),
        any(c.isdigit() for c in v),
        any(not c.isalnum() for c in v),
    ])


def looks_high_entropy(value):
    """Heuristic: does this look like an actual secret rather than prose?"""
    v = value.strip().strip("\"'`*.,;()[]")
    if len(v) < 12 or v.lower() in PROSE_VALUES:
        return False
    if v.startswith("<") and v.endswith(">"):   # placeholder like <PFX_PW>
        return False
    return _class_count(v) >= 3


# "pass" / "pw" are everyday words -- "tests pass:", "Pro Pass:", "first pass:" -- so the shared
# 2-classes rule below read prose as credentials ('**forms-portal' = lower + '-'; a code span
# `subscriptionState="Active"`), and transcript-autosave, which fails closed on any HOT hit in rendered/,
# then refused every archive commit until a human looked. These two labels get a stricter value test;
# the long labels (password/token/secret/...) keep the loose, over-redact-is-cheap rule.
# A first cut of this test also spared any value OPENING with markup (` * # ( < ...) and demanded 20+ chars
# or a digit, so 'Pass: `Kx9#...`', 'PW: **Hunter2!**' and 'Pass: HunterGreen' went into rendered/
# verbatim. The markup test is gone (the value is judged with its wrapping stripped) and mixed case or 16+
# chars count again. What is deliberately still spared: one letter-case + a symbol, no digit, under 16
# chars ('**forms-portal', 'hunter!!') -- the price of keeping everyday 'pass:' prose cold.
# Over-redacting a NEW render is cheap (it renders as [REDACTED], which rescans cold). The real constraint
# is the ALREADY-rendered files: a rule change that turns one of them HOT stalls the fail-closed archive
# gate until it is re-rendered. Check `scan transcripts/rendered` after any change here.
_SHORT_LABEL = re.compile(r"\s*(?:pass|pw)\s*[:=]", re.IGNORECASE)
_KV_OPEN = re.compile(r"[$@-]*([A-Za-z_][\w.-]*)=[\"']")          # a value that opens with key=" or key='
_SECRETISH = re.compile(r"pass|pw|pwd|secret|token|key|cred", re.IGNORECASE)
# What is left of a value once our own mask is removed, when the mask WAS that assignment's value:
# '--admin-password=', 'tokenName=""', 'secret: '. The secret is already masked, so it is not hot.
_MASKED_KV_RESIDUE = re.compile(r"[$@-]*[A-Za-z_][\w.-]*\s*[:=]?\s*[\"'`]*")
_RUN = re.compile(r"\S+")


def assignment_is_secret(value, label=""):
    """Looser gate for `password:/token:/secret: <value>` assignments (the one non-always pattern
    that carries a value). Tightened 2026-08-24 sweep: the old 3-of-4-classes-AND-len>=12 rule let
    a weak-but-real password through verbatim ("companyname2026" = 2 classes; "correcthorse…" = 1)
    and the render auto-pushes to GitHub. Over-redaction is CHEAP in this conversation-only tier; a
    leaked credential is not — so mask any value that is 8+ chars with 2+ character classes, OR 16+
    chars of anything, unless it's obviously prose or a placeholder."""
    v = value.strip().strip("\"'`*.,;()[]{}")
    if len(v) < 8 or v.lower() in PROSE_VALUES:
        return False
    if v.startswith("<") and v.endswith(">"):   # placeholder like <PFX_PW>
        return False
    # Technical tokens are NOT credentials, and "token:/id:" carry them constantly in debug work:
    # short .NET metadata tokens (@0600597A, 0x0A000989), memory addresses, RIDs. But a LONG hex value
    # after a secret keyword IS likely a real key (a 32-char hex API token), so only exclude SHORT hex
    # (< 20 chars — pass-2 found the unbounded exclusion leaked 32-char hex secrets). All-caps constant
    # NAMES (HTTP_CSRF_TOKEN) are excused via _IDENTISH. (Branded real tokens — AKIA…, ghp_…,
    # github_pat_…, sk_live_…, Bearer …, private keys, conn-strings — are caught by always=True above.)
    if (_HEXISH.fullmatch(v) and len(v) < 20) or _IDENTISH.fullmatch(v):
        return False
    if _SHORT_LABEL.match(label):
        # key="value" attribute syntax ('Pro Pass: planState="Active"') is code, not a credential -- but
        # only when the value OPENS with a non-secret key. Anywhere-in-the-value let a credential through
        # when another attribute followed it ('@{Pass="..";User=".."}') or the key was a compound secret
        # name the label regex cannot see ('pw: DB_PASSWORD="..."').
        kv = _KV_OPEN.match(value.strip().lstrip("`*([{"))
        if kv and not _SECRETISH.search(kv.group(1)):
            return False
        # a real pasted credential: 3+ classes, or digits mixed in, or mixed case, or passphrase-long
        return (_class_count(v) >= 3 or (any(c.isdigit() for c in v) and _class_count(v) >= 2)
                or (any(c.isupper() for c in v) and any(c.islower() for c in v)) or len(v) >= 16)
    return _class_count(v) >= 2 or len(v) >= 16


# ---------------------------------------------------------------- parsing

def iter_records(path):
    """Yield parsed records, skipping anything malformed. Streams — safe on 80 MB files."""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                yield lineno, json.loads(line)
            except json.JSONDecodeError:
                continue


def clean_user_text(text):
    """Strip harness-injected wrappers from a user turn."""
    text = NOISE_RE.sub("", text)
    text = OPEN_TAG_RE.sub("", text)
    return text.strip()


def display_title(meta):
    """Prefer the harness's own session title; fall back to the opening prompt."""
    if meta.get("title"):
        return meta["title"]
    prompt = (meta.get("first_prompt") or "").replace("\n", " ").strip()
    if prompt:
        return prompt[:70].rstrip(" .…") + ("…" if len(prompt) > 70 else "")
    return f"Session {meta['session_id'][:8]}"


def local_time(ts):
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return None


def session_meta(path):
    """Cheap header scan: first/last timestamp, cwd, branch, title, counts."""
    meta = {
        "session_id": Path(path).stem,
        "path": str(path),
        "title": None,
        "first_prompt": None,
        "cwd": None,
        "branch": None,
        "version": None,
        "first": None,
        "last": None,
        "user_turns": 0,
        "assistant_turns": 0,
        "tool_calls": 0,
        "images": 0,
        "sidechain": 0,
        "bytes": Path(path).stat().st_size,
    }
    for _, rec in iter_records(path):
        ts = rec.get("timestamp")
        if ts:
            meta["first"] = meta["first"] or ts
            meta["last"] = ts
        meta["cwd"] = meta["cwd"] or rec.get("cwd")
        meta["branch"] = meta["branch"] or rec.get("gitBranch")
        meta["version"] = meta["version"] or rec.get("version")

        # Titles are rewritten as the session evolves — the last one wins.
        if rec.get("type") == "ai-title":
            val = rec.get("aiTitle") or rec.get("title")
            if isinstance(val, str) and val.strip():
                meta["title"] = val.strip()
        elif rec.get("type") == "last-prompt" and not meta["first_prompt"]:
            val = rec.get("lastPrompt")
            if isinstance(val, str) and val.strip():
                meta["first_prompt"] = val.strip()
        if rec.get("isSidechain"):
            meta["sidechain"] += 1
            continue

        msg = rec.get("message") or {}
        content = msg.get("content")
        rtype = rec.get("type")
        if rtype == "user":
            if isinstance(content, str):
                if clean_user_text(content):
                    meta["user_turns"] += 1
            elif isinstance(content, list):
                if any(b.get("type") == "text" and clean_user_text(b.get("text", ""))
                       for b in content if isinstance(b, dict)):
                    meta["user_turns"] += 1
                meta["images"] += sum(
                    1 for b in content if isinstance(b, dict) and b.get("type") == "image")
        elif rtype == "assistant" and isinstance(content, list):
            if any(b.get("type") == "text" for b in content if isinstance(b, dict)):
                meta["assistant_turns"] += 1
            meta["tool_calls"] += sum(
                1 for b in content if isinstance(b, dict) and b.get("type") == "tool_use")
    return meta


# ---------------------------------------------------------------- rendering

def render(path, mode="conversation", thinking=False, tool_results=False,
           include_sidechains=False):
    meta = session_meta(path)
    out = []
    started = local_time(meta["first"])
    ended = local_time(meta["last"])

    out.append(f"# {display_title(meta)}\n")
    out.append("| | |")
    out.append("|---|---|")
    out.append(f"| Session | `{meta['session_id']}` |")
    if started:
        out.append(f"| Started | {started:%Y-%m-%d %H:%M} |")
    if ended:
        out.append(f"| Ended | {ended:%Y-%m-%d %H:%M} |")
    out.append(f"| Working dir | `{meta['cwd'] or '?'}` |")
    if meta["branch"]:
        out.append(f"| Branch | `{meta['branch']}` |")
    out.append(
        f"| Volume | {meta['user_turns']} prompts · {meta['assistant_turns']} replies "
        f"· {meta['tool_calls']} tool calls · {meta['bytes'] / 1e6:.1f} MB raw |")
    out.append(f"| Render mode | `{mode}`"
               + (" +thinking" if thinking else "")
               + (" +tool-results" if tool_results else "") + " |")
    out.append("")
    if mode == "conversation":
        out.append("> Conversation only — tool calls collapsed, tool output omitted.")
        out.append("")
    out.append("---\n")

    pending_tools = []       # collapse runs of tool calls into one line
    last_stamp = None

    def flush_tools():
        if not pending_tools:
            return
        counts = {}
        for name in pending_tools:
            counts[name] = counts.get(name, 0) + 1
        parts = [f"{n} ×{c}" if c > 1 else n for n, c in counts.items()]
        out.append(f"`⚙ {len(pending_tools)} tool call"
                   f"{'s' if len(pending_tools) != 1 else ''}: {', '.join(parts)}`\n")
        pending_tools.clear()

    for _, rec in iter_records(path):
        if rec.get("isSidechain") and not include_sidechains:
            continue
        rtype = rec.get("type")
        if rtype not in ("user", "assistant"):
            continue
        msg = rec.get("message") or {}
        content = msg.get("content")
        stamp = local_time(rec.get("timestamp"))

        if rtype == "user":
            blocks = [{"type": "text", "text": content}] if isinstance(content, str) \
                else (content if isinstance(content, list) else [])
            texts, images = [], 0
            for b in blocks:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text":
                    cleaned = clean_user_text(b.get("text", ""))
                    if cleaned:
                        texts.append(cleaned)
                elif b.get("type") == "image":
                    images += 1
                elif b.get("type") == "tool_result" and tool_results:
                    payload = b.get("content")
                    if not isinstance(payload, str):
                        payload = json.dumps(payload, default=str)
                    snippet = payload[:1500]
                    if len(payload) > 1500:
                        snippet += f"\n… [{len(payload) - 1500} more chars]"
                    flush_tools()
                    out.append("<details><summary>tool result</summary>\n")
                    out.append("```\n" + snippet + "\n```\n")
                    out.append("</details>\n")
            if not texts and not images:
                continue
            flush_tools()
            head = "## 👤 the user"
            if stamp and (last_stamp is None or (stamp - last_stamp).total_seconds() > 900):
                head += f"  ·  {stamp:%Y-%m-%d %H:%M}"
            last_stamp = stamp or last_stamp
            out.append(head + "\n")
            for t in texts:
                out.append(t + "\n")
            if images:
                out.append(f"*[{images} image{'s' if images > 1 else ''} attached]*\n")

        else:  # assistant
            if not isinstance(content, list):
                continue
            for b in content:
                if not isinstance(b, dict):
                    continue
                btype = b.get("type")
                if btype == "thinking" and thinking:
                    flush_tools()
                    out.append("<details><summary>thinking</summary>\n")
                    out.append("> " + b.get("thinking", "").replace("\n", "\n> ") + "\n")
                    out.append("</details>\n")
                elif btype == "text":
                    text = (b.get("text") or "").strip()
                    if not text:
                        continue
                    flush_tools()
                    out.append("## 🤖 Claude\n")
                    out.append(text + "\n")
                elif btype == "tool_use":
                    pending_tools.append(b.get("name", "?"))

    flush_tools()
    return "\n".join(out).rstrip() + "\n", meta


# ---------------------------------------------------------------- scanning

def scan_text(text, redact=False, strict=False):
    """Return (hits, text). hits = [(lineno, name, context, was_redacted)].

    strict=True drops the prose allowance for the short 'pass'/'pw' labels (they are judged like
    'password:'). atoms-lint uses it: an atom claim is short and curated, so over-flagging one is a
    cheap lint failure, never an archive stall.

    Our own mask '[REDACTED]' inside a captured value is opaque: it is removed and only the rest is judged,
    so scanning redacted output is idempotent. Without this, 'scheme://user:[REDACTED]@host' re-matched
    conn-string and the fail-closed rescan refused every archive commit -- and spawn-checkpoint begin with
    it; 'pass: password=[REDACTED]' read as a 3-class value the same way.

    Scans EVERY pattern's EVERY match on each line. The old version ran one .search() per pattern
    and `break`ed after the first pattern that hit the line — so a line carrying two credentials
    redacted only one, and a second occurrence of the same pattern was never seen (2026-08-24 sweep,
    #1 critical). Now: collect all matches, mask the hot ones right-to-left (so earlier spans stay
    valid), merging overlaps. Masking is applied to the DISPLAY context unconditionally — printing
    raw context is how a scan re-leaks the very thing it found into this session's own transcript
    (happened on the first run, 2026-07-26)."""
    hits = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        matches = _line_matches(line, strict)
        if not matches:
            continue
        display = _mask(line, matches)
        # Redaction is a FIXPOINT: masking one value can expose another verdict
        # ('pass: --admin-password="x"' -> 'pass: --admin-password=[REDACTED]', whose outer pass: value is
        # then 17 chars of residue), so re-scan the masked line until nothing hot is left. The rendered
        # output therefore always rescans clean -- the property the fail-closed archive gate depends on.
        # It converges in <= 2 extra rounds on 100k fuzz lines; if it ever did not, the gate's own rescan
        # would still see the hot span and refuse loudly, never pass it.
        for _round in range(6):
            again = [x for x in _line_matches(display, strict) if x[2]]
            if not again:
                break
            matches += again
            display = _mask(display, again)
        if redact and display != line:
            lines[i] = display
        ctx = display.strip()
        if len(ctx) > 90:
            ctx = ctx[:90] + "…"
        for span, name, hot in matches:
            hits.append((i + 1, name, ctx, hot))
    return hits, ("\n".join(lines) + "\n" if redact else text)


def _line_matches(line, strict=False):
    """[(span_or_None, name, hot)] for every match of every pattern on one line."""
    matches = []
    run_ends = None
    hot_until = -1                         # end of the furthest HOT run-value so far
    for name, pat, group, always in SECRET_PATTERNS:
        for m in pat.finditer(line):
            if group == "run":             # the value is the rest of this whitespace-free run (looked up)
                s = m.end()
                if s < hot_until:          # inside a value already judged hot: its mask covers this one, and
                    continue               # judging it would re-copy the run (quadratic on 'pass:pass:...')
                if run_ends is None:
                    run_ends = [r.end() for r in _RUN.finditer(line)]
                span = (s, run_ends[bisect.bisect_right(run_ends, s)])
                value = line[span[0]:span[1]]
            elif group is not None:
                value, span = m.group(group), m.span(group)
            else:
                value, span = None, None
            masked = value is not None and "[REDACTED]" in value
            if masked:                     # our own mask is opaque: judge only what is left around it
                value = value.replace("[REDACTED]", "")
            if masked and (not value.strip(" \t\"'`*.,;()[]{}")
                           or (name == "assignment" and _MASKED_KV_RESIDUE.fullmatch(value.strip(" \t*.,;()[]{}")))):
                hot = False                # only the mask (or a key whose value IS the mask): already redacted
            elif always:
                hot = True
            elif value is None:
                hot = False                # markerless pattern (e.g. pfx): report only
            elif name == "assignment":
                hot = assignment_is_secret(value, "" if strict else line[m.start():span[0]])   # label + separator
            else:
                hot = looks_high_entropy(value)
            if hot and group == "run":
                hot_until = max(hot_until, span[1])
            matches.append((span, name, hot))
    return matches


def _mask(line, matches):
    """Replace every hot, spanned match with [REDACTED], merging overlaps (right-to-left keeps spans valid)."""
    red = sorted(sp for (sp, name, hot) in matches if hot and sp is not None)
    merged = []
    for s, e in red:
        if merged and s <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])
    for s, e in reversed(merged):
        line = line[:s] + "[REDACTED]" + line[e:]
    return line


def report_scan(label, hits):
    if not hits:
        print(f"  clean: {label}")
        return 0, 0
    hot = [h for h in hits if h[3]]
    print(f"  ⚠ {len(hits)} match(es) in {label}"
          + (f" — {len(hot)} look like real secrets" if hot else " — all look like prose"))
    for lineno, name, ctx, is_hot in hits[:25]:
        print(f"      {'‼' if is_hot else '·'} L{lineno} [{name}] {ctx}")
    if len(hits) > 25:
        print(f"      … {len(hits) - 25} more")
    return len(hits), len(hot)


# ---------------------------------------------------------------- commands

STATE_FILE = Path(__file__).parent / ".render-state.json"


def load_state():
    """session_id -> {mtime, size, out, arc}.

    Lets the hook skip untouched sessions WITHOUT parsing them. That matters: deciding
    the output filename normally needs a full parse (the name comes from the title), and
    a full parse of the archive is ~15 s. Machine-local, so it's gitignored.
    """
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(state):
    try:
        STATE_FILE.write_text(json.dumps(state, indent=1), encoding="utf-8")
    except OSError:
        pass


def unchanged(state, path, key):
    """True if `path` is byte-identical to when we last produced its `key` output.

    🛑 STAMPS ARE PER-OPERATION. They used to be a single shared mtime/size per
    session, with only the output NAME kept per key — and that silently poisoned the
    archive. Sequence: render a live session (small), the session keeps growing,
    then `archive` runs and refreshes the SHARED mtime/size to the now-large file.
    The next `render` sees its `out` name present and the shared stamp matching the
    current file, concludes "unchanged", and skips — permanently.

    Cost when it bit (found 2026-08-02): the 07-29 a machine session ran three days
    and 90 prompts through the entire PRR pipeline. It archived correctly at 12.8 MB
    but sat in rendered/ as an 8 KB, two-prompt stub, and the tracked tier is the
    one that gets pushed, searched by setup/recall.py, and survives a machine loss.
    A silent stub is worse than a missing file: nothing looks wrong.

    Do NOT re-merge these stamps. `render` and `archive` observe the same file at
    different times and must track it independently.
    """
    prev = state.get(path.stem)
    if not prev or not prev.get(key):
        return None
    st = path.stat()
    m, s = prev.get(f"{key}_mtime"), prev.get(f"{key}_size")
    if m is None or s is None:
        return None          # legacy shared-stamp entry: redo once, then it self-heals
    if m != st.st_mtime or s != st.st_size:
        return None
    return prev[key]


def remember(state, path, key, name):
    st = path.stat()
    entry = state.setdefault(path.stem, {})
    entry.update({key: name, f"{key}_mtime": st.st_mtime, f"{key}_size": st.st_size})


def project_dir(slug):
    return PROJECTS_ROOT / (slug or DEFAULT_PROJECT)


def project_dirs(slug):
    """Resolve --project to one or more transcript directories.

    `ALL` matches every project dir holding transcripts. The hook uses it because the
    slug is derived from the repo's absolute path, which differs per machine and per user
    (`C--Users-<name>-Claude-Memory`). Hard-coding one name would silently archive nothing
    on any other machine.
    """
    if (slug or "").upper() == "ALL":
        return sorted(d for d in PROJECTS_ROOT.iterdir()
                      if d.is_dir() and any(d.glob("*.jsonl")))
    return [project_dir(slug)]


def all_sessions(slug):
    return sorted((p for d in project_dirs(slug) if d.exists()
                   for p in d.glob("*.jsonl")),
                  key=lambda p: p.stat().st_mtime)


def find_session(ident, slug):
    p = Path(ident)
    if p.exists():
        return p
    direct = project_dir(slug) / f"{ident}.jsonl"
    if direct.exists():
        return direct
    matches = sorted(project_dir(slug).glob(f"{ident}*.jsonl"))
    if len(matches) == 1:
        return matches[0]
    if not matches:
        sys.exit(f"No session matching '{ident}' in {project_dir(slug)}")
    sys.exit("Ambiguous session id; matches:\n  " +
             "\n  ".join(m.stem for m in matches))


def slugify(text, fallback):
    s = re.sub(r"[^\w\s-]", "", (text or "").lower()).strip()
    s = re.sub(r"[\s_]+", "-", s)[:60].strip("-")
    return s or fallback


def cmd_index(args):
    files = all_sessions(args.project)
    if not files:
        sys.exit("No transcripts found for --project "
                 f"{args.project} under {PROJECTS_ROOT}")
    print("\n".join(str(d) for d in project_dirs(args.project)) + "\n")
    for f in files:
        m = session_meta(f)
        start = local_time(m["first"])
        print(f"{m['session_id'][:8]}  {start:%Y-%m-%d %H:%M}" if start
              else f"{m['session_id'][:8]}  {'?':16}", end="")
        print(f"  {m['bytes'] / 1e6:6.1f} MB  "
              f"{m['user_turns']:4} prompts  {m['tool_calls']:5} tools   "
              f"{display_title(m)}")


EXCLUDE_FILE = Path(__file__).parent / "render-exclude.txt"


def load_excludes():
    """Session ids the user has deliberately chosen NOT to keep a transcript of.

    Some sessions are scrapped on purpose. the user, on the 07-29 a machine
    session: "I very intentionally decided to keep the work and scrap the transcript...
    The lesson learned from that one will stick with me even without a transcript."
    The handoff exists precisely so the work survives without the conversation.

    This list is TRACKED, not gitignored, because the decision has to travel. Without
    it the per-operation stamp fix would faithfully re-render a discarded session on
    every machine, forever -- a correctness fix quietly overriding a human decision.
    Deletion alone cannot hold: the next render puts it straight back.
    """
    out = set()
    try:
        for ln in EXCLUDE_FILE.read_text(encoding="utf-8").splitlines():
            ln = ln.split("#", 1)[0].strip()
            if ln:
                out.add(ln)
    except OSError:
        pass
    return out


_SESSION_LINE = re.compile(r"^\| Session \| `([^`]+)` \|", re.MULTILINE)


def rendered_session(path):
    """The session id in a rendered file's header table (render() writes it, --redact keeps it), or None."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            head = "".join(fh.readline() for _ in range(12))
    except OSError:
        return None
    m = _SESSION_LINE.search(head)
    return m.group(1) if m else None


def cmd_render(args):
    targets = (all_sessions(args.project)
               if args.all else [find_session(args.session, args.project)])
    excludes = load_excludes()
    if excludes:
        keep = [p for p in targets if not any(p.stem.startswith(e) for e in excludes)]
        dropped = len(targets) - len(keep)
        if dropped and not args.quiet:
            print(f"  {dropped} session(s) skipped by render-exclude.txt (deliberate)")
        targets = keep
    mode = "full" if args.full else "conversation"
    thinking = args.thinking or args.full
    tool_results = args.tool_results or args.full

    outdir = Path(args.output) if (args.all and args.output) else None
    if outdir:
        outdir.mkdir(parents=True, exist_ok=True)

    state = load_state() if outdir else {}
    total_hits = skipped = 0
    for path in targets:
        if outdir and not args.force:
            done = unchanged(state, path, "out")
            # skip only while the recorded file still holds THIS session (a collision may have overwritten it)
            if done and (outdir / done).exists() and rendered_session(outdir / done) in (None, path.stem):
                skipped += 1
                continue

        text, meta = render(path, mode=mode, thinking=thinking,
                            tool_results=tool_results,
                            include_sidechains=args.sidechains)
        if args.all:
            start = local_time(meta["first"])
            stamp = f"{start:%Y-%m-%d}" if start else "undated"
            name = f"{stamp}-{slugify(display_title(meta), meta['session_id'][:8])}.md"
            dest = (outdir or Path(".")) / name
            # Two sessions opening with the same prompt on the same day ('load my memory', 'Try again') share
            # a name, and the last writer silently replaced the other's transcript -- six sessions on one box
            # once mapped to a single file. A name that already holds ANOTHER session's
            # transcript gets this session's short id appended, so both survive. No existing name changes.
            owner = rendered_session(dest)
            if owner and owner != meta["session_id"]:
                dest = dest.with_name(f"{dest.stem}-{meta['session_id'][:8]}.md")
        elif args.output:
            dest = Path(args.output)
        else:
            dest = None

        hits, text = scan_text(text, redact=args.redact)
        if dest:
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(text, encoding="utf-8")
            _, hot = report_scan(str(dest), hits) if not args.quiet \
                else (0, sum(1 for h in hits if h[3]))
            total_hits += hot
            if outdir:
                # A retitled session renames its output — drop the stale copy, but only if it IS this
                # session's (after a name collision the recorded name can hold another session's transcript).
                stale = (state.get(path.stem) or {}).get("out")
                if stale and stale != dest.name and rendered_session(outdir / stale) in (None, meta["session_id"]):
                    (outdir / stale).unlink(missing_ok=True)
                remember(state, path, "out", dest.name)
            if not args.quiet:
                print(f"  wrote {dest.name}  ({len(text) / 1000:.0f} KB, "
                      f"{meta['user_turns']} prompts)")
        else:
            print(text)

    if outdir:
        save_state(state)
    if skipped and not args.quiet:
        print(f"  {skipped} unchanged, skipped")
    if total_hits:
        verb = "redacted" if args.redact else "left in place"
        print(f"\n⚠ {total_hits} likely secret(s) {verb}. "
              + ("Re-read before committing."
                 if args.redact else "Do NOT commit without --redact."))


MIRROR_CONFIG = Path(__file__).parent / "mirror-target.txt"


def cmd_mirror(args):
    """Copy the archive to a second location (NAS), verifying what lands.

    the user's call 2026-07-26, and it's the right instinct: *"it's easy to throw away data
    you don't need later - it's rough as hell getting it back if you threw away something
    you need."* The raw tier is gitignored, so without this it exists in exactly one
    place — on a box with confirmed bad RAM.

    Which is also why every copied .gz is read back through gzip afterward: gzip carries
    a CRC32, so a bit flipped in transit or in RAM shows up as a decompression error
    instead of silently rotting in the backup. A backup made on failing hardware that
    nobody verified is not a backup.

    Target comes from --target, else transcripts/mirror-target.txt (gitignored — the path
    is machine-specific and a home NAS path has no business on a district machine).
    Missing config or unreachable target = silent no-op, so the hook never breaks when
    the user is off the home LAN.
    """
    target = args.target
    if not target and MIRROR_CONFIG.exists():
        for line in MIRROR_CONFIG.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                target = line
                break
    if not target:
        if not args.quiet:
            print(f"No mirror target. Set one:\n  echo '\\\\\\\\nas\\\\share' > "
                  f"{MIRROR_CONFIG}")
        return

    dest_root = Path(target)
    try:
        reachable = dest_root.exists() or dest_root.parent.exists()
    except OSError:
        reachable = False
    if not reachable:
        if not args.quiet:
            print(f"⚠ mirror target unreachable, skipping: {dest_root}")
        return

    here = Path(__file__).parent
    copied = verified = failed = 0
    for sub in ("raw", "rendered"):
        src_dir, dst_dir = here / sub, dest_root / sub
        if not src_dir.exists():
            continue
        dst_dir.mkdir(parents=True, exist_ok=True)
        for src in sorted(src_dir.iterdir()):
            if not src.is_file():
                continue
            dst = dst_dir / src.name
            if dst.exists() and dst.stat().st_size == src.stat().st_size \
                    and dst.stat().st_mtime >= src.stat().st_mtime:
                continue
            shutil.copy2(src, dst)
            copied += 1

            if src.suffix == ".gz":
                try:
                    with gzip.open(dst, "rb") as fh:
                        while fh.read(4 * 1024 * 1024):
                            pass
                    verified += 1
                except (OSError, EOFError) as exc:
                    failed += 1
                    print(f"  ‼ CORRUPT AFTER COPY: {dst.name} — {exc}")
                    print("     Re-run. If it repeats, suspect RAM (see environment.md).")
            if not args.quiet:
                print(f"  mirrored  {sub}/{src.name}")

    # Leave a breadcrumb so the backup explains itself without this repo.
    try:
        (dest_root / "README.txt").write_text(
            "Claude Code session archive, mirrored from your Claude-Memory repo.\n"
            "  raw/       full .jsonl.gz — EVERY tool result verbatim. Treat as\n"
            "             credential-bearing: it can contain secrets and private\n"
            "             session material. Not in git, by design.\n"
            "  rendered/  conversation only, secrets redacted. Also on your private\n"
            "             GitHub repo.\n"
            "Rebuild or re-render with transcripts/render-session.py in that repo.\n",
            encoding="utf-8")
    except OSError:
        pass

    if not args.quiet or failed:
        print(f"\n{dest_root}\n  {copied} copied, {verified} gzip-verified"
              + (f", ⚠ {failed} CORRUPT" if failed else ""))
    if failed:
        sys.exit(1)


# ── DRIFT: selective off-box copy of the raw tier to a second, narrower target ──────────────────────
# `mirror` copies EVERYTHING to one target. Some machines need a second copy that is choosier: e.g. a work
# machine whose raw tier may go to the work archive in full, but to a personal NAS only for the sessions
# that never handled sensitive records. The line drawn here: a transcript is a RECORD OF WORK unless record
# CONTENT entered Claude's context. Listing, moving or inventorying a data root, or running a pipeline over
# it, is work; so is building the tooling. So `drift` copies to drift-target.txt only the sessions the
# policy clears, while mirror-target.txt (if set) still takes everything.
#   HOLD  record content entered Claude's context: Read/Grep of a path under a data `root`; any other tool
#         whose input names a root AND a `reader` verb (cat, Get-Content, Import-Csv, grep...); a `tool`
#         that returns records (a mail / chat / document connector); or a `match` (record URLs / APIs)
#   DRIFT none of that, AND the session has been quiet `settle` hours (classification is final)
#   Explicit `hold`/`drift` lines in drift-policy.txt (your call) beat the classifier.
# It never deletes: a HELD session already on the target is reported for you to remove.
DRIFT_POLICY = Path(__file__).parent / "drift-policy.txt"
DRIFT_TARGET = Path(__file__).parent / "drift-target.txt"
DRIFT_STATE = Path(__file__).parent / ".drift-state.json"
DRIFT_RAW = Path(__file__).parent / "raw"         # the local archive `drift` reads (tests repoint it)


def load_drift_policy(path=None):
    path = path or DRIFT_POLICY      # resolved at CALL time (a def-time default ignored a repointed policy)
    pol = {"root": [], "reader": [], "workfile": [], "tool": [], "match": [], "hold": [], "drift": [],
           "settle": 12.0, "hash": "none"}
    if not Path(path).exists():
        return pol
    text = Path(path).read_text(encoding="utf-8")
    pol["hash"] = hashlib.sha1(text.encode("utf-8")).hexdigest()[:12]   # a policy edit re-classifies all
    for raw in text.splitlines():
        ln = raw.strip()
        if not ln or ln.startswith("#"):
            continue
        kw, _, val = ln.partition(" ")
        val = val.split(" #", 1)[0].strip()       # trailing "  # reason" comments
        if not val:
            continue
        if kw == "root":
            # Drive-less, backslash-normalized: C:\Records, C:/Records and Git Bash's
            # /c/Records all reduce to "\records".
            key = re.sub(r"\\+", r"\\", val.replace("/", "\\")).lower().rstrip("\\")
            pol["root"].append(re.sub(r"^[a-z]:", "", key))
        elif kw in ("reader", "workfile", "tool", "match"):
            pol[kw].append(re.compile(val, re.IGNORECASE))
        elif kw in ("hold", "drift"):
            pol[kw].append(val.lower()[:8])
        elif kw == "settle":
            pol["settle"] = float(val)
    return pol


def _strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from _strings(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _strings(v)


# Tools that put a file's CONTENT into Claude's context: a root in their path field is a read.
_CONTENT_PATH = {"Read": ("file_path",), "NotebookRead": ("notebook_path",), "Grep": ("path",)}
# Tools whose inputs are Claude's OWN text or only file names: never a read of record content. (Writing
# ABOUT a data root into a doc -- even the policy file itself -- is not touching it.)
_NO_CONTENT = {"Write", "Edit", "MultiEdit", "NotebookEdit", "Glob"}


def _norm(s):
    return re.sub(r"\\+", r"\\", s.replace("/", "\\")).lower()


_PATH_TOKEN = re.compile(r"[A-Za-z]:[\\/][^\s'\"|;,)`]*|/[A-Za-z]/[^\s'\"|;,)`]*")


def _data_paths(s, pol):
    """Root-bearing paths named in s that are NOT pipeline telemetry (`workfile`): the record candidates."""
    out = []
    for p in _PATH_TOKEN.findall(s):
        n = _norm(p).rstrip("\\")
        if any(r in n for r in pol["root"]) and not any(w.search(n) for w in pol["workfile"]):
            out.append(n)
    return out


def _session_id8(name):
    m = re.search(r"\.([0-9a-f]{8})\.jsonl(\.gz)?$", name)
    return m.group(1) if m else name[:8].lower()


def classify_raw(path, pol):
    """-> (decision, reason, last_ts). decision: hold | drift | wait. Streams the whole file."""
    sid = _session_id8(Path(path).name)
    for p in pol["hold"]:
        if sid.startswith(p):
            return "hold", "policy: hold " + p, None
    forced = any(sid.startswith(p) for p in pol["drift"])
    opener = gzip.open if str(path).endswith(".gz") else open
    last = None
    with opener(path, "rt", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            last = rec.get("timestamp") or last
            if forced or rec.get("type") != "assistant":
                continue
            content = (rec.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for b in content:
                if not isinstance(b, dict) or b.get("type") != "tool_use":
                    continue
                name, inp = b.get("name") or "", b.get("input")
                for rx in pol["tool"]:
                    if rx.search(name):
                        return "hold", "tool: " + rx.pattern, last
                if name in _NO_CONTENT:
                    continue
                if name in _CONTENT_PATH and isinstance(inp, dict):
                    for f in _CONTENT_PATH[name]:
                        v = inp.get(f)
                        if isinstance(v, str):
                            n = _norm(v)
                            if any(w.search(n) for w in pol["workfile"]):
                                continue          # reading the pipeline's own log/manifest = work
                            for r in pol["root"]:
                                if r in n:
                                    return "hold", f"read: {name} {r}", last
                    continue
                for s in _strings(inp):
                    if _data_paths(s, pol):
                        for rx in pol["reader"]:
                            if rx.search(s):
                                return "hold", f"read: {name} + {rx.pattern}", last
                    for rx in pol["match"]:
                        if rx.search(s):
                            return "hold", "match: " + rx.pattern, last
    ts = local_time(last)
    if ts is not None:
        age_h = (datetime.now().astimezone() - ts).total_seconds() / 3600
        if age_h < pol["settle"]:
            return "wait", f"active {age_h:.1f}h ago (settle {pol['settle']:g}h)", last
    return "drift", "policy: drift" if forced else "work record only", last


def classify_dir(raw_dir, pol, cache=None):
    """Classify every *.jsonl.gz in raw_dir; reuse cache[name] when size+mtime are unchanged."""
    out = []
    for f in sorted(Path(raw_dir).glob("*.jsonl.gz")):
        st = f.stat()
        key = f"{st.st_size}:{int(st.st_mtime)}:{pol['hash']}"
        c = (cache or {}).get(f.name)
        if c and c.get("key") == key and c.get("decision") in ("hold", "drift"):
            out.append((f, c["decision"], c["reason"]))
            continue
        decision, reason, _ = classify_raw(f, pol)
        if cache is not None and decision in ("hold", "drift"):
            cache[f.name] = {"key": key, "decision": decision, "reason": reason}
        out.append((f, decision, reason))
    return out


def cmd_classify(args):
    pol = load_drift_policy()
    rows = classify_dir(args.dir or DRIFT_RAW, pol)
    for f, decision, reason in rows:
        print(f"  {decision.upper():5}  {_session_id8(f.name)}  {reason:42.42}  {f.name[:60]}")
    n = {d: sum(1 for _, x, _ in rows if x == d) for d in ("hold", "drift", "wait")}
    print(f"\n  {len(rows)} session(s): {n['drift']} drift, {n['hold']} hold, {n['wait']} still settling")


def cmd_drift(args):
    target = args.target
    if not target and DRIFT_TARGET.exists():
        target = next((l.strip() for l in DRIFT_TARGET.read_text(encoding="utf-8").splitlines()
                       if l.strip() and not l.strip().startswith("#")), None)
    if not target:
        if not args.quiet:
            print(f"No drift target. Put one line in {DRIFT_TARGET} (the narrower archive, e.g. a\n"
                  f"  personal NAS share). Absent file = drift is off on this box.")
        return
    dest = Path(target) / "raw"
    try:
        reachable = Path(target).exists()
    except OSError:
        reachable = False
    if not reachable:
        if not args.quiet:
            print(f"⚠ drift target unreachable, skipping: {target}")
        return
    pol = load_drift_policy()
    try:
        cache = json.loads(DRIFT_STATE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        cache = {}
    rows = classify_dir(DRIFT_RAW, pol, cache)
    dest.mkdir(parents=True, exist_ok=True)
    drifted = held = waiting = failed = 0
    for src, decision, reason in rows:
        dst = dest / src.name
        if decision == "hold":
            held += 1
            if dst.exists():   # was drifted before a policy change; Claude never deletes from the target
                print(f"  ‼ HELD BUT ON TARGET -- remove it by hand: {dst}  ({reason})")
            continue
        if decision == "wait":
            waiting += 1
            continue
        if dst.exists() and dst.stat().st_size == src.stat().st_size \
                and dst.stat().st_mtime >= src.stat().st_mtime:
            continue
        shutil.copy2(src, dst)
        try:
            with gzip.open(dst, "rb") as fh:
                while fh.read(4 * 1024 * 1024):
                    pass
            drifted += 1
            if not args.quiet:
                print(f"  drifted   raw/{src.name}")
        except (OSError, EOFError) as exc:
            failed += 1
            print(f"  ‼ CORRUPT AFTER COPY: {dst.name} -- {exc}")
    try:
        DRIFT_STATE.write_text(json.dumps(cache, indent=1), encoding="utf-8")
    except OSError:
        pass
    if not args.quiet or failed:
        print(f"\n{target}\n  {drifted} drifted (gzip-verified), {held} held, {waiting} settling"
              + (f", ⚠ {failed} CORRUPT" if failed else ""))
    if failed:
        sys.exit(1)


def cmd_prompts(args):
    """Print only the user's turns across sessions — the corpus for mining memory.

    Task detail is already well captured in memory/. What gets lost between sessions is
    the relational layer: how he wants to be worked with, what he reacts well or badly
    to. That signal is in what he says, not in what the tools did.
    """
    targets = (all_sessions(args.project)
               if args.all else [find_session(args.session, args.project)])
    pat = re.compile(args.grep, re.IGNORECASE) if args.grep else None
    shown = 0
    for path in targets:
        meta = session_meta(path)
        header_done = False
        for _, rec in iter_records(path):
            if rec.get("type") != "user" or rec.get("isSidechain"):
                continue
            content = (rec.get("message") or {}).get("content")
            blocks = [{"type": "text", "text": content}] if isinstance(content, str) \
                else (content if isinstance(content, list) else [])
            for b in blocks:
                if not isinstance(b, dict) or b.get("type") != "text":
                    continue
                text = clean_user_text(b.get("text", ""))
                if not text or (pat and not pat.search(text)):
                    continue
                if not header_done:
                    print(f"\n{'=' * 70}\n{display_title(meta)}\n"
                          f"{meta['session_id'][:8]}\n{'=' * 70}")
                    header_done = True
                stamp = local_time(rec.get("timestamp"))
                print(f"\n--- {stamp:%Y-%m-%d %H:%M} ---" if stamp else "\n---")
                print(text[:args.max_chars])
                if len(text) > args.max_chars:
                    print(f"[… {len(text) - args.max_chars} more chars]")
                shown += 1
    print(f"\n\n{shown} turn(s).")


def cmd_archive(args):
    """Compress raw .jsonl into the local archive so re-rendering stays possible.

    Deliberately NOT tracked by git: the raw files are large and contain every tool
    result verbatim (credentials, FERPA material, config dumps). See README.md.
    """
    dest_dir = Path(args.output or (Path(__file__).parent / "raw"))
    dest_dir.mkdir(parents=True, exist_ok=True)

    state = load_state()
    raw_total = comp_total = 0
    skipped = 0
    for path in all_sessions(args.project):
        raw_total += path.stat().st_size

        done = None if args.force else unchanged(state, path, "arc")
        if done and (dest_dir / done).exists():
            comp_total += (dest_dir / done).stat().st_size
            skipped += 1
            continue

        meta = session_meta(path)
        start = local_time(meta["first"])
        stamp = f"{start:%Y-%m-%d}" if start else "undated"
        dest = dest_dir / (f"{stamp}-{slugify(display_title(meta), 'session')}"
                           f".{meta['session_id'][:8]}.jsonl.gz")

        with open(path, "rb") as fin, gzip.open(dest, "wb", compresslevel=9) as fout:
            shutil.copyfileobj(fin, fout, length=1024 * 1024)

        stale = (state.get(path.stem) or {}).get("arc")
        if stale and stale != dest.name:
            (dest_dir / stale).unlink(missing_ok=True)
        remember(state, path, "arc", dest.name)

        comp_total += dest.stat().st_size
        if not args.quiet:
            print(f"  archived  {dest.name}  "
                  f"({path.stat().st_size / 1e6:.1f} → {dest.stat().st_size / 1e6:.1f} MB)")
    save_state(state)

    if not args.quiet and raw_total:
        print(f"\n{dest_dir}\n  {raw_total / 1e6:.1f} MB raw → {comp_total / 1e6:.1f} MB "
              f"compressed ({100 * comp_total / raw_total:.0f}%)"
              + (f", {skipped} unchanged" if skipped else ""))


def cmd_scan(args):
    p = Path(args.target)
    files = sorted(p.rglob("*.md")) if p.is_dir() else [p]
    total_hot = 0
    unreadable = []
    for f in files:
        # A path past Windows' 260-char MAX_PATH (a deep TMPDIR clone) raised out of this loop, so a scan
        # crash read as "a secret SURVIVED" to every caller. Retry long paths with
        # the extended-length prefix; anything still unreadable is reported and exits 2, not 1.
        try:
            original = f.read_text(encoding="utf-8", errors="replace")
        except OSError:
            try:
                original = Path("\\\\?\\" + str(f.resolve())).read_text(encoding="utf-8", errors="replace") \
                    if os.name == "nt" else None
            except OSError:
                original = None
            if original is None:
                unreadable.append(f)
                print(f"  UNREADABLE: {f}")
                continue
        hits, cleaned = scan_text(original, redact=args.redact)
        _, hot = report_scan(str(f), hits)
        total_hot += hot
        if args.redact and cleaned != original:
            f.write_text(cleaned, encoding="utf-8")
            print(f"      → redacted in place: {f.name}")
    print(f"\n{len(files)} file(s), {total_hot} likely secret(s)"
          + (f", {len(unreadable)} UNREADABLE (not scanned)." if unreadable else "."))
    if total_hot and not args.redact:
        sys.exit(1)
    sys.exit(2 if unreadable else 0)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    pi = sub.add_parser("index", help="list stored sessions")
    pi.add_argument("--project", default=DEFAULT_PROJECT)
    pi.set_defaults(func=cmd_index)

    pr = sub.add_parser("render", help="render session(s) to Markdown")
    pr.add_argument("session", nargs="?", help="session id (or prefix) or path")
    pr.add_argument("--all", action="store_true", help="render every session")
    pr.add_argument("--project", default=DEFAULT_PROJECT)
    pr.add_argument("-o", "--output", help="output file, or directory with --all")
    pr.add_argument("--full", action="store_true",
                    help="thinking + tool results (NOT commit-safe unreviewed)")
    pr.add_argument("--thinking", action="store_true")
    pr.add_argument("--tool-results", action="store_true")
    pr.add_argument("--sidechains", action="store_true", help="include subagent turns")
    pr.add_argument("--redact", action="store_true",
                    help="mask high-entropy secret values in the output")
    pr.add_argument("--force", action="store_true", help="re-render unchanged sessions")
    pr.add_argument("--quiet", action="store_true", help="hook mode: errors only")
    pr.set_defaults(func=cmd_render)

    pp = sub.add_parser("prompts", help="print only the user's turns (memory-mining corpus)")
    pp.add_argument("session", nargs="?")
    pp.add_argument("--all", action="store_true")
    pp.add_argument("--project", default=DEFAULT_PROJECT)
    pp.add_argument("--grep", help="only turns matching this regex")
    pp.add_argument("--max-chars", type=int, default=1200)
    pp.set_defaults(func=cmd_prompts)

    pm = sub.add_parser("mirror", help="copy the archive to a NAS, verifying gzip CRCs")
    pm.add_argument("--target", help="destination root (default: mirror-target.txt)")
    pm.add_argument("--quiet", action="store_true", help="hook mode: errors only")
    pm.set_defaults(func=cmd_mirror)

    pc = sub.add_parser("classify", help="drift-policy verdict (hold/drift/wait) per archived session")
    pc.add_argument("--dir", help="a raw/ dir to classify (default: ./raw; a NAS raw/ dir audits it)")
    pc.set_defaults(func=cmd_classify)

    pd = sub.add_parser("drift", help="copy policy-cleared raw sessions to drift-target.txt")
    pd.add_argument("--target", help="destination root (default: drift-target.txt)")
    pd.add_argument("--quiet", action="store_true", help="hook mode: errors + held-on-target only")
    pd.set_defaults(func=cmd_drift)

    pa = sub.add_parser("archive", help="gzip raw transcripts into the local archive")
    pa.add_argument("--project", default=DEFAULT_PROJECT)
    pa.add_argument("-o", "--output", help="archive dir (default: ./raw)")
    pa.add_argument("--force", action="store_true", help="re-archive unchanged sessions")
    pa.add_argument("--quiet", action="store_true", help="hook mode: errors only")
    pa.set_defaults(func=cmd_archive)

    ps = sub.add_parser("scan", help="scan rendered markdown for secrets")
    ps.add_argument("target")
    ps.add_argument("--redact", action="store_true", help="mask hits in place")
    ps.set_defaults(func=cmd_scan)

    args = ap.parse_args()
    if args.cmd == "render" and not args.all and not args.session:
        ap.error("render needs a session id, or --all")
    args.func(args)


if __name__ == "__main__":
    main()
