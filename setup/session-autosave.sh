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
# PULL-FIRST) pauses on a conflict, the session ends its turn to ask Paul how to resolve — and
# ending the turn fires THIS hook. Left unchecked, `git add -A` would stage the conflict MARKERS
# as the resolution and commit them into canon under a generic message, erasing the real one; the
# next push then ships marker soup fleet-wide. So bail out (leaving everything exactly as-is for
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

# Clean? Then discipline already handled it — drop any stale hint/marker and stay invisible.
if [ -z "$(git -C "${REPO}" status --porcelain)" ]; then
  rm -f "${HINT}" "${FAILMARK}" "${ATOMSMARK}"
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

# ── ATOMS: WRITE-PATH GATE (F-A) + PATH-SCOPED COMMIT (F-E) ─────────────────────────────────────
# F-A: atoms-lint is otherwise only a MANUAL doctor (dr-check), so a malformed / duplicate-id / off-vocab /
#   secret-inlining atom would ride THIS auto-push to every machine before anything validates it. If
#   memory/atoms.jsonl is staged and FAILS lint, hold JUST that file back; the rest of the tree still commits.
# F-E: if it PASSES (or can't be linted — no python), commit atoms.jsonl in its OWN path-scoped commit,
#   isolated from the .md bundle, so a `git revert` of a bad atom can never cross into a source .md. Both are
#   contained to the atoms layer (atoms.jsonl is tracked, restores byte-identical → never risks the repo).
ATOMSCOMMITTED=""
[ -n "$(git -C "${REPO}" status --porcelain -- memory/atoms.jsonl 2>/dev/null)" ] || rm -f "${ATOMSMARK}"
if git -C "${REPO}" diff --cached --name-only -- memory/atoms.jsonl | grep -q .; then
  APY=""
  for c in "py -3" python3 python; do
    if $c -c "import sys" >/dev/null 2>&1; then APY="$c"; break; fi
  done
  if [ -n "${APY}" ] && ! $APY "${REPO}/setup/atoms-lint.py" "${REPO}/memory/atoms.jsonl" >/dev/null 2>&1; then
    # F-A: bad atom — hold it back from commit/push, drop a marker (rest of the tree still commits below).
    git -C "${REPO}" restore --staged -- memory/atoms.jsonl 2>/dev/null \
      || git -C "${REPO}" reset -q HEAD -- memory/atoms.jsonl
    printf 'atoms-lint FAILED %s — memory/atoms.jsonl HELD BACK from commit/push (a bad atom must not reach other machines). Fix it: `py -3 setup/atoms-lint.py`, then it commits normally. The REST of your work committed fine.\n' \
      "$(date '+%Y-%m-%d %H:%M')" > "${ATOMSMARK}"
    echo "session-autosave: atoms.jsonl FAILED atoms-lint — held back from the push (rest committed). See ~/Claude-Memory/.git/atoms-lint-FAILED." >&2
  else
    # F-E: clean (or unlintable) → commit atoms.jsonl ALONE (pathspec = revert-isolated from any .md).
    rm -f "${ATOMSMARK}"
    if git -C "${REPO}" commit -q -m "atoms: fast-fact autosave $(date '+%Y-%m-%d %H:%M') (path-scoped, revert-isolated — F-E)" -- memory/atoms.jsonl 2>/dev/null; then
      ATOMSCOMMITTED=1
    fi
  fi
fi

# Nothing actually staged? Then this was a no-op (only rendered/ was dirty, or a CRLF renormalization
# left the tree phantom-dirty). That is a clean-equivalent, NOT a backstop failure — clear any
# hint/marker and stay invisible. (Pass-2 #5: the old code let a no-op commit's rc=1 write a FALSE
# autosave-FAILED marker that check-canon announced as "canon may not be saving", training dismissal
# of the very marker the fail-loud path exists for.)
if git -C "${REPO}" diff --cached --quiet; then
  rm -f "${HINT}" "${FAILMARK}"
  # If only atoms changed, the F-E path-scoped commit above still needs to ship (the main push below is
  # skipped because we exit here). No-op if nothing is actually ahead.
  [ -n "${ATOMSCOMMITTED}" ] && git -C "${REPO}" push -q origin main 2>/dev/null
  exit 0
fi

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
git -C "${REPO}" push -q origin main 2>/dev/null || true

exit 0
