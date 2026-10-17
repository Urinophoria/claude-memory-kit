#!/usr/bin/env bash
# session-autosave.sh — Stop hook (STANDARDS §2 "PUSH + DOCUMENT before you stop").
#
# Backstop for the WRITE half of the discipline: if a session ends (or a turn ends) with
# UNCOMMITTED memory changes, commit + push them so work can't strand the way the dashboard
# session's did. This is the replacement for the retired project-sync daemon — it lives inside
# the app lifecycle, so there's no long-running process to crash on a desktop OS.
#
# Conservative by design (mirrors check-canon.sh):
#   - NO-OP when the tree is clean (the session already committed per discipline → invisible).
#   - NEVER rebases/merges/touches anyone else's commits. If push is rejected (origin moved),
#     it leaves the local commit in place; the next SessionStart's check-canon warns "behind,"
#     the session pulls-first, and this commit ships then. Nothing is ever lost or clobbered.
#   - Auto-commit messages are clearly tagged so they're distinguishable from descriptive ones;
#     descriptive same-session commits are still preferred (this is the net, not the plan).
#
# Wired as a Stop hook in .claude/settings.json. Travels to every machine via git.
#
# COMMIT-MESSAGE HINT (added 2026-08-15). If a session has written a message to
# `.git/autosave-msg` (easiest via `setup/next-commit.sh "subject" "" "body…"`), THIS commit uses
# it verbatim instead of the generic "auto:" text, then clears it. That lets multi-turn work land
# under a descriptive, authored message + body on the backstop commit itself — so a session never
# has to add a *second* commit just to explain a previous auto-commit (the friction this solves).
# Nothing else changes: still commits + fast-forward-pushes any dirty tree every Stop (the
# intentional aggression). Hint absent → behaviour is identical to before. The hint lives in
# `.git/` so it is never staged, and is cleared on EVERY run (including a clean-tree exit) so a
# stale hint can never attach itself to an unrelated later change.

REPO="${HOME}/Claude-Memory"
HINT="${REPO}/.git/autosave-msg"
FAILMARK="${REPO}/.git/autosave-FAILED"
HELDMARK="${REPO}/.git/autosave-HELD"
ATOMSMARK="${REPO}/.git/atoms-lint-FAILED"
[ -d "${REPO}/.git" ] || exit 0

# ── SAFETY BAILOUT (2026-08-26, T1 of the memory-system sweep) ────────────────────────────────
# NEVER auto-commit while the repo is mid-operation. If a `git rebase origin/main` (the mandated
# PULL-FIRST) pauses on a conflict, the session ends its turn to ask you how to resolve — and
# ending the turn fires THIS hook. Left unchecked, `git add -A` would stage the conflict MARKERS
# as the resolution and commit them into canon under a generic message, erasing the real one; the
# next push then ships marker soup to every machine. So bail out (leaving everything exactly as-is for
# the human to finish) on ANY of: a merge / cherry-pick / revert in progress, a rebase in progress,
# an unmerged index, or a HEAD that isn't `main`. This is the fix for the sweep's #1 critical.
GITDIR=$(git -C "${REPO}" rev-parse --absolute-git-dir 2>/dev/null)
if git -C "${REPO}" rev-parse --verify --quiet MERGE_HEAD        >/dev/null 2>&1 \
 || git -C "${REPO}" rev-parse --verify --quiet CHERRY_PICK_HEAD >/dev/null 2>&1 \
 || git -C "${REPO}" rev-parse --verify --quiet REVERT_HEAD      >/dev/null 2>&1 \
 || { [ -n "${GITDIR}" ] && { [ -d "${GITDIR}/rebase-merge" ] || [ -d "${GITDIR}/rebase-apply" ]; }; } \
 || [ -n "$(git -C "${REPO}" ls-files -u 2>/dev/null)" ] \
 || [ "$(git -C "${REPO}" symbolic-ref --short -q HEAD 2>/dev/null)" != "main" ]; then
  echo "session-autosave: repo is mid-operation (rebase/merge/conflict) or not on main — SKIPPING autosave so a partial/conflicted state can't be committed into canon. Finish the operation, then commit." >&2
  # FAIL-LOUD on the bailout too (2026-08-26 pass-2 #2): the T1 fix made this path skip SILENTLY, so a
  # session killed mid-rebase stranded ALL its uncommitted work with no durable warning (check-canon
  # sees HEAD==origin so behind=0, says nothing). Drop a HELD marker the next SessionStart announces.
  printf 'autosave HELD %s — repo is mid-operation (rebase/merge/conflict) or off main. Uncommitted work is NOT backed up on this box. Finish the operation (e.g. resolve the rebase, or git rebase --abort), then let autosave run.\n' \
    "$(date '+%Y-%m-%d %H:%M')" > "${HELDMARK}"
  exit 0
fi

# Not mid-operation anymore → clear any stale HELD marker.
rm -f "${HELDMARK}"

# ── ATOMS-LINT GATE: helpers (F-A, atoms-safety audit 2026-08-28; widened 2026-09-30) ─────────────
# F-A originally linted ONLY when memory/atoms.jsonl was staged. But a .md-only edit that names a
# nonexistent atom (a DANGLING ref, e.g. 'std-999') is a HARD lint failure too, and it rode this
# auto-push to other machines unlinted -- including the rest-of-tree commit this hook makes at turn end
# right after canon-save has REFUSED that very save. So now the gate runs whenever anything is staged.
#
# lint_index lints the STAGED INDEX, mirrored into a scratch tree -- NOT the working tree. Once the gate
# holds a file back, the commit no longer equals the working tree, and only the index ships. The cascade
# that proves it: atoms.jsonl held back for one bad atom -> a .md that references a NEW, valid atom in
# it now dangles against HEAD's atoms.jsonl. A working-tree lint passes that; the commit is broken.
# Sets LINT_RC: 0 clean | 1 hard failure(s), with LINT_IMPL = the implicated repo-relative paths |
# 2 could not lint (lint crashed / snapshot sync failed) -- treated as a failure, fail loud |
# 3 no python -> proceed unlinted (the pre-existing "unlintable -> proceed" rule; nothing to gate with).
SNAPD="${GITDIR:-${REPO}/.git}/atoms-lint-snap"
# What the lint reads: every .md (dangling-ref walk + src resolution), the atoms file, and the secret
# scanner it imports. (Exclude only transcripts' .md -- a bare 'transcripts' exclude drops the scanner.)
LINT_PATHS=('*.md' ':(exclude)transcripts/*.md' 'memory/atoms.jsonl' 'transcripts/render-session.py')

# sync_snapshot: make ${SNAPD}/tree match the index's LINT_PATHS. The mirror PERSISTS in .git/ and only
# changed paths are rewritten, because on Windows the first read of a freshly written file pays the AV
# scan: a full re-export measured ~3.5s per lint vs ~0.4s warm -- too slow for several hold-back rounds
# under this hook's 30s timeout. tree-id records the index tree the mirror matches; it is deleted BEFORE
# applying a delta and rewritten only after, so a killed sync forces a full re-export, never a stale pass.
sync_snapshot() {
  local new old st p
  new=$(git -C "${REPO}" write-tree) || return 1
  old=$(cat "${SNAPD}/tree-id" 2>/dev/null)
  [ -n "${old}" ] && [ "${new}" = "${old}" ] && [ -d "${SNAPD}/tree" ] && return 0
  rm -f "${SNAPD}/tree-id"
  if [ -n "${old}" ] && [ -d "${SNAPD}/tree" ] \
     && git -C "${REPO}" diff-tree -r -z --no-renames --name-status "${old}" "${new}" -- "${LINT_PATHS[@]}" \
          > "${SNAPD}/delta" 2>/dev/null; then
    : > "${SNAPD}/files" || return 1
    while IFS= read -r -d '' st && IFS= read -r -d '' p; do
      case "${st}" in
        D) rm -f "${SNAPD}/tree/${p}" || return 1 ;;
        *) printf '%s\0' "${p}" >> "${SNAPD}/files" ;;
      esac
    done < "${SNAPD}/delta"
    git -C "${REPO}" checkout-index -f -z --stdin --prefix="${SNAPD}/tree/" < "${SNAPD}/files" || return 1
  else
    # First run on this box, or the recorded tree is gone (gc) -- full export. No pipes: a failed export
    # must fail the sync, never pass as a clean lint.
    rm -rf "${SNAPD}/tree" && mkdir -p "${SNAPD}/tree" \
      && git -C "${REPO}" ls-files -z -- "${LINT_PATHS[@]}" > "${SNAPD}/files" \
      && git -C "${REPO}" checkout-index -z --stdin --prefix="${SNAPD}/tree/" < "${SNAPD}/files" \
      || return 1
  fi
  printf '%s\n' "${new}" > "${SNAPD}/tree-id"
}

APY="-"
lint_index() {
  LINT_IMPL=""; LINT_FIRST=""
  if [ "${APY}" = "-" ]; then
    APY=""
    for c in "py -3" python3 python; do
      if $c -c "import sys" >/dev/null 2>&1; then APY="$c"; break; fi
    done
  fi
  [ -n "${APY}" ] || { LINT_RC=3; return; }
  mkdir -p "${SNAPD}" && rm -f "${SNAPD}/implicated" "${SNAPD}/out"
  if ! sync_snapshot; then
    LINT_RC=2; LINT_FIRST="could not mirror the staged index for linting"; return
  fi
  $APY "${REPO}/setup/atoms-lint.py" --root "${SNAPD}/tree" --implicated "${SNAPD}/implicated" \
       "${SNAPD}/tree/memory/atoms.jsonl" > "${SNAPD}/out" 2>&1
  if [ $? -eq 0 ]; then
    LINT_RC=0
  elif [ -f "${SNAPD}/implicated" ]; then
    LINT_RC=1
    LINT_IMPL="$(tr -d '\r' < "${SNAPD}/implicated")"
    # First HARD line, glyph stripped by pattern -- NOT `cut -c`, which counts BYTES here and would split
    # the 3-byte UTF-8 glyph (or claim text) mid-character inside the marker check-canon injects.
    LINT_FIRST="$(grep -m1 -E '^  (✗|X) ' "${SNAPD}/out")"
    LINT_FIRST="${LINT_FIRST#  ✗ }"; LINT_FIRST="${LINT_FIRST#  X }"
  else
    LINT_RC=2; LINT_FIRST="lint CRASHED: $(tr -d '\r' < "${SNAPD}/out" | tail -n1)"
  fi
}

# hold_back PATH: unstage one path. The WORKING TREE is never touched (a new file goes back to untracked,
# a staged deletion back into the index), so nothing is lost -- it just doesn't commit or push yet.
HELD=""
hold_back() {
  git -C "${REPO}" --literal-pathspecs restore --staged -- "$1" 2>/dev/null \
    || git -C "${REPO}" --literal-pathspecs reset -q HEAD -- "$1" 2>/dev/null
  HELD="${HELD}${HELD:+ }$1"
}

# A marker exists but there is nothing to commit: clear it only if HEAD (== the index here) now lints
# clean. It used to be cleared blindly on a clean tree -- which would silence a withheld bad tip and leave
# check-canon's bare "N commits ahead, push them" inviting a raw push of exactly what the gate withheld.
recheck_marker() {
  [ -f "${ATOMSMARK}" ] || return 0
  lint_index
  [ "${LINT_RC}" = 0 ] && rm -f "${ATOMSMARK}"
  return 0
}

# Clean? Then discipline already handled it — drop any stale hint/marker and stay invisible.
if [ -z "$(git -C "${REPO}" status --porcelain)" ]; then
  rm -f "${HINT}" "${FAILMARK}"
  recheck_marker
  exit 0
fi

# Message: a session-authored hint (descriptive) if present, else the generic backstop tag.
if [ -s "${HINT}" ]; then
  MSG="$(cat "${HINT}")"
else
  MSG="auto: Stop-hook session-save $(date '+%Y-%m-%d %H:%M') (backstop — see STANDARDS §2)"
fi

# EXCLUDE transcripts/rendered from the stage (2026-08-26, pass-2 #1 critical). transcript-autosave.sh
# is the SOLE committer of that tree, and its fail-closed secret gate withholds a rendered file when a
# secret survived redaction (leaving it dirty for review). Without this exclude, THIS blind `git add -A`
# would sweep that withheld file into a commit and push it — voiding the gate and re-opening the
# secret-exposure critical. So the Stop-hook backstop never touches rendered/; it lands at the next
# session boundary through transcript-autosave (which scans first).
git -C "${REPO}" add -A -- ':(exclude)transcripts/rendered'

# Nothing actually staged? Then this was a no-op (only rendered/ was dirty, or a CRLF renormalization
# left the tree phantom-dirty). That is a clean-equivalent, NOT a backstop failure — clear any
# hint/marker and stay invisible. (Pass-2 #5: the old code let a no-op commit's rc=1 write a FALSE
# autosave-FAILED marker that check-canon announced as "canon may not be saving", training dismissal
# of the very marker the fail-loud path exists for.)
if git -C "${REPO}" diff --cached --quiet; then
  rm -f "${HINT}" "${FAILMARK}"
  recheck_marker
  exit 0
fi

# ── ATOMS-LINT GATE (F-A) + PATH-SCOPED ATOMS COMMIT (F-E) ────────────────────────────────────────
# F-A: lint what is about to be committed. On a HARD failure, HOLD BACK (unstage) the staged files the
#   lint implicates -- atoms.jsonl for a bad atom, every .md carrying a dangling ref, a staged delete of a
#   src .md -- and re-lint, until the commit lints clean. The held files stay dirty here, uncommitted, so no
#   pusher (this hook, transcript-autosave, a raw push) can carry them; everything else still commits and
#   pushes, because nobody watches a Stop hook and stranding the whole tree for one bad ref is worse.
#   (canon-save, the watched foreground path, refuses the WHOLE save instead.) Marker -> check-canon.
#   Rejected: commit-all-but-skip-the-push. transcript-autosave pushes HEAD at every session boundary and
#   check-canon's "ahead" note invites a raw push, so a committed bad tip leaks; an uncommitted one can't.
# Fallback: if it STILL fails with nothing staged left to blame, the failure is already in HEAD, not from
#   this turn. Commit anyway (never lose work). Push only if HEAD had no local-only commits (the failure is
#   then already on origin; pushing can't make it worse). Otherwise -- or if the 8-round cap cut the
#   hold-back short -- PUSH WITHHELD, marked; transcript-autosave honors that keyword.
# F-E: a clean atoms.jsonl commits in its OWN path-scoped commit, isolated from the .md bundle, so a
#   `git revert` of a bad atom can never cross into a source .md.
AHEAD_BEFORE=$(git -C "${REPO}" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
lint_index
GATE_FIRST="${LINT_FIRST}"
rounds=0
while { [ "${LINT_RC}" = 1 ] || [ "${LINT_RC}" = 2 ]; } && [ "${rounds}" -lt 8 ]; do
  rounds=$((rounds+1))
  staged=$'\n'"$(git -C "${REPO}" -c core.quotePath=false diff --cached --name-only --no-renames)"$'\n'
  offenders=""
  while IFS= read -r p; do
    case "${staged}" in *$'\n'"${p}"$'\n'*) [ -n "${p}" ] && offenders="${offenders}${p}"$'\n' ;; esac
  done <<< "${LINT_IMPL}"
  # Last resort: nothing staged is named, but atoms.jsonl is staged. It is the other half of every
  # cross-ref (an atom removed out from under an unchanged .md), the owner of a typo'd new src, and the
  # only file whose content can crash the lint. Hold it; the re-lint says whether that was enough.
  if [ -z "${offenders}" ]; then
    case "${staged}" in *$'\n'"memory/atoms.jsonl"$'\n'*) offenders="memory/atoms.jsonl"$'\n' ;; esac
  fi
  [ -n "${offenders}" ] || break
  while IFS= read -r p; do [ -n "${p}" ] && hold_back "${p}"; done <<< "${offenders}"
  lint_index
done

# Withhold when the remaining failure can't be proven to be origin's already: HEAD had local-only commits,
# or the round cap cut the hold-back short (staged offenders may remain -- never push those).
NOPUSH=""; STILLBAD=""
case "${LINT_RC}" in 1|2)
  STILLBAD=1
  { [ "${AHEAD_BEFORE:-0}" -gt 0 ] 2>/dev/null || [ "${rounds}" -ge 8 ]; } && NOPUSH=1 ;;
esac
if [ -n "${HELD}${STILLBAD}" ]; then
  {
    printf 'atoms-lint FAILED %s.' "$(date '+%Y-%m-%d %H:%M')"
    [ -n "${HELD}" ] && printf ' HELD BACK (still dirty here: uncommitted, not pushed): %s.' "${HELD}"
    if [ -n "${NOPUSH}" ]; then
      printf ' PUSH WITHHELD: the tip still fails and the cause may not be on origin yet (committed here, NOT pushed; do not raw-push). Still failing: %s.' "${LINT_FIRST}"
    elif [ -n "${STILLBAD}" ]; then
      printf ' The tip STILL fails from a pre-existing cause already on origin (pushed anyway): %s.' "${LINT_FIRST}"
    else
      printf ' Why: %s.' "${GATE_FIRST}"
    fi
    printf ' Everything else committed. Fix: py -3 setup/atoms-lint.py -- clears on the next autosave that lints clean.\n'
  } > "${ATOMSMARK}"
  echo "session-autosave: atoms-lint FAILED — held back: ${HELD:-nothing}${NOPUSH:+; PUSH WITHHELD}. See ~/Claude-Memory/.git/atoms-lint-FAILED." >&2
elif [ "${LINT_RC}" = 0 ]; then
  rm -f "${ATOMSMARK}"
fi

ATOMSCOMMITTED=""
if ! git -C "${REPO}" diff --cached --quiet -- memory/atoms.jsonl; then
  if git -C "${REPO}" \
        commit -q -m "atoms: fast-fact autosave $(date '+%Y-%m-%d %H:%M') (path-scoped, revert-isolated — F-E)" \
        -- memory/atoms.jsonl 2>/dev/null; then
    ATOMSCOMMITTED=1
  fi
fi

# Nothing left staged (everything held back, or atoms.jsonl was the only change and F-E committed it).
if git -C "${REPO}" diff --cached --quiet; then
  rm -f "${FAILMARK}"
  # A hint describes the held work, so keep it for when that lands; otherwise clear it (never let a stale
  # hint attach to an unrelated later change).
  [ -n "${HELD}" ] || rm -f "${HINT}"
  # The F-E commit is real work that still needs to ship (the main push below is skipped by this exit).
  [ -n "${ATOMSCOMMITTED}" ] && [ -z "${NOPUSH}" ] && git -C "${REPO}" push -q origin main 2>/dev/null
  exit 0
fi

# The history says what the commit does NOT contain, so an authored hint can't claim held-back work.
[ -n "${HELD}" ] && MSG="${MSG}"$'\n\n'"[autosave] HELD BACK, failed atoms-lint (left uncommitted): ${HELD}"

# Something is staged. FAIL-LOUD: on a blocked commit (e.g. a stale .git/index.lock left by a
# timeout-killed hook), keep the hint and drop a marker that the next SessionStart's check-canon
# announces (a Stop hook's own stdout isn't surfaced).
if git -C "${REPO}" \
      commit -q -m "${MSG}" 2>/dev/null; then
  rm -f "${HINT}" "${FAILMARK}"
else
  printf 'commit failed %s — staged changes present but commit blocked (stale .git/index.lock?). Hint preserved.\n' \
    "$(date '+%Y-%m-%d %H:%M')" > "${FAILMARK}"
  echo "session-autosave: COMMIT FAILED — canon backstop did not save. See ~/Claude-Memory/.git/autosave-FAILED." >&2
  exit 0
fi

# Push only as a fast-forward; do NOT rebase/merge here (that could surprise-clobber).
# A non-fast-forward reject (origin moved) is the BENIGN, by-design case: the commit stays local and
# the next SessionStart's check-canon reports "behind" (diverged), the session pulls-first, and this
# commit ships then. An ahead-only unpushed state (push failed for another reason) is ALSO now caught
# by check-canon's ahead-check — so both push-failure modes surface next session without a marker here.
# PUSH WITHHELD (gate fallback above) skips it; the marker explains.
[ -n "${NOPUSH}" ] || git -C "${REPO}" push -q origin main 2>/dev/null || true

exit 0
