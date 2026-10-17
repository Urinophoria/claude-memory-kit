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
set -uo pipefail

REPO="${HOME}/Claude-Memory"
cd "${REPO}" || { echo "[spawn-checkpoint] FAILED: no canon at ${REPO}" >&2; exit 1; }
GITDIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || { echo "[spawn-checkpoint] FAILED: not a git repo" >&2; exit 1; }
BEGIN="${GITDIR}/spawn-checkpoint-begin"
OKSTAMP="${GITDIR}/spawn-checkpoint-OK"
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
  WAIVE=""
  if [ "${2:-}" = "--mirror-waived" ]; then
    WAIVE="${3:-}"; [ -n "${WAIVE}" ] || die "--mirror-waived needs a reason (the user's words)"
  fi
  rm -f "${OKSTAMP}"
  [ -n "${PY}" ] || die "no python -- render-session.py cannot archive"
  T0=$(date +%s)
  # (1a) archive + render + secret-gated commit of rendered/ + push: the SAME sanctioned path the session
  #      boundary uses (transcript-autosave is the sole committer of rendered/; it honors PUSH WITHHELD).
  #      The live session's transcript is included, so a spawned session can READ its parent from canon.
  bash "${REPO}/setup/transcript-autosave.sh" || true
  NEWEST=$($PY - "${REPO}/transcripts/raw" <<'PYEOF'
import os, sys
d = sys.argv[1]
ts = [os.path.getmtime(os.path.join(d, f)) for f in os.listdir(d) if f.endswith(".gz")] if os.path.isdir(d) else []
print(int(max(ts)) if ts else 0)
PYEOF
)
  [ "${NEWEST:-0}" -ge "${T0}" ] || die "the archive refreshed nothing (no raw .gz written this run) -- run: py -3 transcripts/render-session.py archive --project ALL, and read its error"
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
  [ -f "${BEGIN}" ] || die "no begin stamp -- run: bash setup/spawn-checkpoint.sh begin"
  read -r T0 _ BASE MREST < "${BEGIN}"
  case "${MREST}" in mirror=pending*) die "the transcript mirror is still pending (connect it, then begin again)";; esac
  NOW=$(date +%s); [ $(( NOW - T0 )) -le 7200 ] || die "begin stamp is over 2 h old -- run begin again (the transcript moved on)"
  [ -z "$(git status --porcelain -- . ':(exclude)transcripts/rendered')" ] || die "tree is dirty -- save with setup/canon-save.sh first"
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
  printf '%s OK %s | %s\n' "$(date +%s)" "${RESULT#OK }" "${MREST}" > "${OKSTAMP}"
  echo "[spawn-checkpoint] VERIFIED: ${RESULT#OK }; ${MREST}."
  echo "  ARMED: setup/spawn-guard.sh allows new sessions for the next 60 min. Name the atom + the updated files in the brief."
  ;;

status)
  [ -f "${BEGIN}" ] && echo "begin:  $(cat "${BEGIN}")" || echo "begin:  (none)"
  [ -f "${OKSTAMP}" ] && echo "armed:  $(cat "${OKSTAMP}")" || echo "armed:  (no)"
  ;;

*) sed -n '2,24p' "$0"; exit 1 ;;
esac
exit 0
