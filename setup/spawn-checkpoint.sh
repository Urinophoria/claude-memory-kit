#!/usr/bin/env bash
# spawn-checkpoint.sh — STANDARDS 2B: the checkpoint BEFORE offering a new session (spawn / fork / branch).
#
# WHY. Spawned sessions can do real work with no human in the loop, handing off through git: one session
# writes its unfixed residual into a commit body, the next one's brief is built from it. But the PARENT's
# reasoning -- why it spawned, what it saw -- lives only in its live transcript: not archived until session
# end, and not mirrored off the box until then either. Lose that session and the "why" is gone. So an offer
# to spin up a new session must FIRST (1) download the transcript (prompting the user to connect the mirror
# on a box that can't reach it), (2) update memory + any relevant project, (3) create an atom referencing
# those updates. Then a spawned session -- or any later one -- reaches the full context through canon, not
# only through its brief.
#
# Usage:
#   bash setup/spawn-checkpoint.sh begin       # step 1: transcript download (archive + render + commit + mirror)
#   bash setup/spawn-checkpoint.sh begin --mirror-waived "why"   # ONLY on the user's explicit say-so in chat
#     ... Claude: step 2 (memory + PROJECT.md/SESSION.md) and step 3 (an atom whose src is one of those files),
#         saved with setup/canon-save.sh ...
#   bash setup/spawn-checkpoint.sh verify      # proves 1-3 landed + pushed; ARMS setup/spawn-guard.sh for 60 min
#   bash setup/spawn-checkpoint.sh status
# Exit: 0 ok | 1 failed (reason printed) | 3 begin done locally but the mirror needs the user (connect, then re-run).
#
# STAMPS ARE PER SESSION: begin/verify key their stamps on CLAUDE_CODE_SESSION_ID
# (set in the Bash tool), and spawn-guard reads the same id from its payload, so one session's checkpoint never
# arms another's spawn -- not even a child started in its parent's folder. A failed begin leaves NO begin stamp
# (it used to leave the previous one, which verify then honored), and verify consumes the begin it proved, so
# one begin arms the guard at most once. Steps 2-3 are any commit after THIS session's begin: that evidence is
# not bound to the session that made it, only the stamps are. Without CLAUDE_CODE_SESSION_ID (a terminal run)
# begin still archives but says it skipped the own-transcript proof, and verify refuses: the shared stamp it
# could write never arms a Claude Code session (the guard honors it only for a payload without a session_id).
set -uo pipefail

REPO="${HOME}/Claude-Memory"
cd "${REPO}" || { echo "[spawn-checkpoint] FAILED: no canon at ${REPO}" >&2; exit 1; }
GITDIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || { echo "[spawn-checkpoint] FAILED: not a git repo" >&2; exit 1; }
SID="$(printf '%s' "${CLAUDE_CODE_SESSION_ID:-}" | tr -cd 'A-Za-z0-9-')"
BEGIN="${GITDIR}/spawn-checkpoint-begin${SID:+.${SID}}"
OKSTAMP="${GITDIR}/spawn-checkpoint-OK${SID:+.${SID}}"
MIRRORCFG="${REPO}/transcripts/mirror-target.txt"
HOST="$(hostname 2>/dev/null || echo this-box)"
die() { printf '[spawn-checkpoint] FAILED: %s\n' "$*" >&2; exit 1; }
PY=""
for c in "py -3" python3 python; do
  if $c -c "import sys" >/dev/null 2>&1; then PY="$c"; break; fi
done

mirror_prompt() {
  cat >&2 <<EOF

[spawn-checkpoint] ⛔ TRANSCRIPT MIRROR NEEDED on ${HOST} -- $1
  The raw tier (transcripts/raw, credential-bearing, NOT in git) has no verified off-box copy here.
  An unreachable mirror is almost always FIXABLE (STANDARDS 7: get the tool) -- so ask, don't skip.
  ASK THE USER to connect this box to its transcript mirror (a NAS share, another disk -- whatever
  transcripts/mirror-target.txt should name on this machine; for a network share, sign in once with
  saved credentials). Claude never types that password. Then write the path into
  transcripts/mirror-target.txt (gitignored: a deliberate per-machine act) and re-run begin.
  Declining is the user's call: begin --mirror-waived "reason" (recorded in the stamp + the atom).
EOF
}

case "${1:-}" in
begin)
  rm -f "${OKSTAMP}" "${BEGIN}"     # a begin that dies below must leave nothing verify could honor
  find "${GITDIR}" -maxdepth 1 -name 'spawn-checkpoint-*.*' -mtime +1 -delete 2>/dev/null   # old sessions' stamps
  WAIVE=""
  if [ "${2:-}" = "--mirror-waived" ]; then
    WAIVE="${3:-}"; [ -n "${WAIVE}" ] || die "--mirror-waived needs a reason (the user's words)"
  fi
  [ -n "${PY}" ] || die "no python -- render-session.py cannot archive"
  T0=$(date +%s)
  # (1a) archive + render + secret-gated commit of rendered/ + push: the SAME sanctioned path the session
  #      boundary uses (transcript-autosave is the sole committer of rendered/; it honors PUSH WITHHELD).
  #      The live session's transcript is included, so a spawned session can READ its parent from canon.
  bash "${REPO}/setup/transcript-autosave.sh" || true
  # transcript-autosave ALWAYS exits 0 (a hook must never break a session), so its exit code proves
  # nothing. The proof is the tree: rendered/ still dirty after it ran = the commit was REFUSED (the
  # fail-closed secret gate, or the mid-operation hold). This step used to print "committed" regardless.
  if [ -n "$(git -C "${REPO}" status --porcelain -- transcripts/rendered)" ]; then
    die "transcript-autosave did NOT commit transcripts/rendered. Its reason is the 'transcript-autosave:' line just above: 'secret SURVIVED' -> run ${PY} transcripts/render-session.py scan transcripts/rendered and fix the HOT line; 'could NOT READ' -> run that scan and fix or remove the UNREADABLE path it names; 'mid-operation or not on main' -> finish the rebase/merge or return to main; no such line -> the commit itself failed (index.lock? git identity?). Then re-run begin"
  fi
  # A clean rendered/ is not proof THIS session's transcript is in canon: a render
  # that crashed (transcript-autosave discards its errors) writes nothing and leaves the tree clean, and a
  # gitignored output name never shows as dirty. So prove the live session's own file: recorded in the render
  # state, written this run (or nothing new since its last render), and tracked by git with no diff.
  if [ -n "${SID}" ]; then
    # Identity is the rendered file's own '| Session | `<id>` |' header, not its name: two sessions with the
    # same first prompt on one day once shared a name (the last writer won, the other's transcript was gone)
    # and the render state can lose an entry to another session's unlocked rewrite. PYTHONIOENCODING: a title
    # outside cp1252 crashed the print on a Windows pipe.
    LIVE=$(PYTHONIOENCODING=utf-8 $PY - "${REPO}" "${SID}" "${T0}" <<'PYEOF'
import json, re, sys, pathlib
repo, sid, t0 = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
tdir = repo / "transcripts"
rdir = tdir / "rendered"
try:
    excl = [l.split("#", 1)[0].strip() for l in (tdir / "render-exclude.txt").read_text(encoding="utf-8").splitlines()]
except OSError:
    excl = []
if any(e and sid.startswith(e) for e in excl):
    print("EXCLUDED"); sys.exit()
SL = re.compile(r"^\| Session \| `([^`]+)` \|", re.MULTILINE)
def owner(p):
    try:
        with open(p, encoding="utf-8", errors="replace") as fh:
            m = SL.search("".join(fh.readline() for _ in range(12)))
        return m.group(1) if m else None
    except OSError:
        return None
try:
    st = json.loads((tdir / ".render-state.json").read_text(encoding="utf-8")).get(sid) or {}
except (OSError, ValueError):
    st = {}
f = rdir / st["out"] if st.get("out") else None
if not (f and f.is_file() and owner(f) == sid):
    mine = [p for p in rdir.glob("*.md") if owner(p) == sid]     # the state lost it or points elsewhere
    f = max(mine, key=lambda p: p.stat().st_mtime) if mine else None
    if not f or f.name != st.get("out"):
        st = {}
if not f:
    print("MISSING no rendered file carries this session's header"); sys.exit()
src = sorted(pathlib.Path.home().glob(".claude/projects/*/" + sid + ".jsonl"))
fresh = f.stat().st_mtime >= t0 or bool(st and src and abs(src[0].stat().st_mtime - st.get("out_mtime", -1)) < 0.01)
print(("OK " if fresh else "STALE ") + f.name)
PYEOF
)
    case "${LIVE}" in
      EXCLUDED) echo "[spawn-checkpoint] note: this session is in transcripts/render-exclude.txt -- deliberately no rendered transcript." ;;
      OK\ *)
        LF="transcripts/rendered/${LIVE#OK }"
        git -C "${REPO}" ls-files --error-unmatch -- "${LF}" >/dev/null 2>&1 \
          || die "this session's transcript ${LF} is NOT tracked by git (a .gitignore pattern? check: git check-ignore -v '${LF}') -- it never reaches canon"
        git -C "${REPO}" diff --quiet HEAD -- "${LF}" \
          || die "this session's transcript ${LF} has uncommitted changes -- transcript-autosave did not commit it"
        git -C "${REPO}" show "HEAD:${LF}" 2>/dev/null | head -12 | grep -qF "| Session | \`${SID}\` |" \
          || die "${LF} in HEAD is ANOTHER session's transcript (a rendered-name collision) -- this session's is not in canon" ;;
      STALE\ *) die "this session's transcript was NOT re-rendered this run (${LIVE#STALE }, older than the live session) -- run: ${PY} transcripts/render-session.py render --all --project ALL -o transcripts/rendered --redact, read its error, then re-run begin" ;;
      MISSING\ *) die "this session's transcript was NOT rendered (${LIVE#MISSING }) -- run: ${PY} transcripts/render-session.py render --all --project ALL -o transcripts/rendered --redact, read its error, then re-run begin" ;;
      *) die "the own-transcript proof itself failed (no verdict from python) -- run: ${PY} transcripts/render-session.py render --all --project ALL -o transcripts/rendered --redact and check this session's file by hand" ;;
    esac
  else
    echo "[spawn-checkpoint] note: no CLAUDE_CODE_SESSION_ID in this shell -- the own-transcript proof was SKIPPED (run begin from the session's own Bash tool)." >&2
  fi
  NEWEST=$($PY - "${REPO}/transcripts/raw" <<'PYEOF'
import os, sys
d = sys.argv[1]
ts = [os.path.getmtime(os.path.join(d, f)) for f in os.listdir(d) if f.endswith(".gz")] if os.path.isdir(d) else []
print(int(max(ts)) if ts else 0)
PYEOF
)
  [ "${NEWEST:-0}" -ge "${T0}" ] || die "the archive refreshed nothing (no raw .gz written this run) -- run: ${PY} transcripts/render-session.py archive --project ALL, and read its error"
  # (1b) the off-box copy.
  MSTAT=""
  TARGET=""
  [ -f "${MIRRORCFG}" ] && TARGET="$(grep -v '^[[:space:]]*#' "${MIRRORCFG}" | grep -m1 -v '^[[:space:]]*$' | tr -d '\r')"
  if [ -n "${WAIVE}" ]; then
    MSTAT="waived: ${WAIVE}"
  elif [ -z "${TARGET}" ]; then
    printf '%s begin %s mirror=pending\n' "${T0}" "$(git rev-parse HEAD)" > "${BEGIN}"
    mirror_prompt "no transcripts/mirror-target.txt on this box"; exit 3
  elif ! $PY -c "import sys,pathlib; p=pathlib.Path(sys.argv[1]); sys.exit(0 if (p.exists() or p.parent.exists()) else 1)" "${TARGET}" 2>/dev/null; then
    printf '%s begin %s mirror=pending\n' "${T0}" "$(git rev-parse HEAD)" > "${BEGIN}"
    mirror_prompt "target ${TARGET} is unreachable (not connected / no credential)"; exit 3
  elif $PY "${REPO}/transcripts/render-session.py" mirror; then
    MSTAT="ok: ${TARGET}"
  else
    die "mirror to ${TARGET} FAILED (CRC/copy error above) -- re-run; if it repeats, suspect RAM"
  fi
  printf '%s begin %s mirror=%s\n' "${T0}" "$(git rev-parse HEAD)" "${MSTAT}" > "${BEGIN}"
  echo "[spawn-checkpoint] step 1 DONE: transcripts archived + rendered + committed; mirror ${MSTAT}."
  echo "  NEXT (Claude): step 2 update memory + every relevant PROJECT.md/SESSION.md; step 3 add an atom whose"
  echo "  src is one of those files; save with setup/canon-save.sh; then: bash setup/spawn-checkpoint.sh verify"
  ;;

verify)
  [ -n "${SID}" ] || die "no CLAUDE_CODE_SESSION_ID in this shell: a verify here could only write the SHARED stamp, which never arms a Claude Code session's spawn -- run verify from the session's own Bash tool"
  [ -f "${BEGIN}" ] || die "no begin stamp -- run: bash setup/spawn-checkpoint.sh begin"
  read -r T0 _ BASE MREST < "${BEGIN}"
  case "${MREST}" in mirror=pending*) die "the transcript mirror is still pending (connect it, then begin again)";; esac
  NOW=$(date +%s); [ $(( NOW - T0 )) -le 7200 ] || die "begin stamp is over 2 h old -- run begin again (the transcript moved on)"
  [ -z "$(git status --porcelain -- . ':(exclude)transcripts/rendered')" ] || die "tree is dirty -- save with setup/canon-save.sh first"
  [ -z "$(git status --porcelain -- transcripts/rendered)" ] \
    || die "transcripts/rendered has uncommitted changes -- the archive commit is refused (secret gate / hold); fix that and re-run begin"
  [ -n "$(git rev-list "${BASE}..HEAD" 2>/dev/null)" ] || die "no commit since begin -- steps 2+3 haven't been saved"
  git fetch -q origin || die "git fetch failed -- can't prove the push"
  git merge-base --is-ancestor HEAD origin/main || die "HEAD is not in origin/main -- push it (setup/canon-save.sh)"
  [ -n "${PY}" ] || die "no python"
  # Step 2 + 3, mechanically: a narrative file changed since begin, AND a NEW atom (an id absent at begin)
  # whose src IS one of the changed files -- "an atom referencing those updates", not just any atom.
  git diff --name-only "${BASE}" HEAD -- 'memory/*.md' 'code/*/PROJECT.md' 'cowork/*/SESSION.md' MEMORY.md > "${GITDIR}/spawn-changed" \
    || die "git diff failed"
  git show "${BASE}:memory/atoms.jsonl" > "${GITDIR}/spawn-atoms-before" 2>/dev/null || : > "${GITDIR}/spawn-atoms-before"
  RESULT=$($PY - "${GITDIR}/spawn-changed" "${GITDIR}/spawn-atoms-before" "${REPO}/memory/atoms.jsonl" <<'PYEOF'
import json, sys
changed = {l.strip() for l in open(sys.argv[1], encoding="utf-8") if l.strip()}
def ids(p):
    out = {}
    for l in open(p, encoding="utf-8-sig", errors="replace"):
        l = l.strip()
        if l.startswith("{"):
            try:
                a = json.loads(l); out[a.get("id")] = a
            except ValueError:
                pass
    return out
new = [a for i, a in ids(sys.argv[3]).items() if i not in ids(sys.argv[2])]
srcfiles = lambda s: {f"memory/{s}.md", f"code/{s}/PROJECT.md"}   # what atoms-lint resolves a src to
tied = [a["id"] for a in new if srcfiles(a.get("src", "")) & changed]
if not changed:
    print("FAIL no memory/*.md, PROJECT.md or SESSION.md changed since begin (step 2)")
elif not new:
    print("FAIL no new atom since begin (step 3)")
elif not tied:
    print("FAIL new atom(s) " + ",".join(a["id"] for a in new) + " but none has its src in the updated files (" + ", ".join(sorted(changed)) + ")")
else:
    print("OK atoms " + ",".join(tied) + " -> " + ", ".join(sorted(changed)))
PYEOF
)
  case "${RESULT}" in OK*) ;; *) die "${RESULT#FAIL }";; esac
  printf '%s OK %s | %s | session=%s\n' "$(date +%s)" "${RESULT#OK }" "${MREST}" "${SID:-none}" > "${OKSTAMP}" \
    || die "could not write ${OKSTAMP} -- nothing armed; re-run verify"
  rm -f "${BEGIN}"   # one begin arms the guard once; a later spawn needs a fresh begin
  echo "[spawn-checkpoint] VERIFIED: ${RESULT#OK }; ${MREST}."
  echo "  ARMED: setup/spawn-guard.sh allows new sessions from THIS session for the next 60 min. Name the atom + the updated files in the brief."
  ;;

status)
  echo "session: ${SID:-(none -- shared, unsuffixed stamps)}"
  [ -f "${BEGIN}" ] && echo "begin:  $(cat "${BEGIN}")" || echo "begin:  (none)"
  [ -f "${OKSTAMP}" ] && echo "armed:  $(cat "${OKSTAMP}")" || echo "armed:  (no)"
  ;;

*) sed -n '2,/^set -uo/{/^#/p}' "$0"; exit 1 ;;
esac
exit 0
