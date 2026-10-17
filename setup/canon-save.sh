#!/usr/bin/env bash
# canon-save.sh -- the sanctioned FOREGROUND "save canon now" path (STANDARDS section 2A).
#
# WHY THIS EXISTS. The Stop-hook autosave + check-canon are built to "fail loud, not fail open" --
# but that hardening lives in the HOOKS. A hand-typed `git ... | tail && git push ...` in the Bash
# tool bypasses all of it: a bash pipeline returns the LAST stage's exit code, so `git <op> | tail`
# reports 0 even when git FAILED, and the `&&` chain sails on. That exact shape can mask a failed
# `git pull --rebase` (dirty tree + wrong order) and a rejected push alike -- silent success on
# non-execution.
#
# This script is the manual-path counterpart to the hardened hooks: ONE correct-by-construction
# command that cannot lie, so a save you do rarely (rare -> under-practiced -> where hand-entry
# burns you) is never hand-rolled.
#
# Guarantees:
#   - set -euo pipefail throughout; NO git op is ever piped (so no exit code is ever masked).
#   - refuses mid-operation states (rebase/merge/cherry-pick/revert, unmerged index, HEAD != main).
#   - correct order: add -> commit -> pull --rebase -> push  (rebase refuses a dirty tree, so
#     commit MUST come first).
#   - authored message REQUIRED (args or the next-commit.sh hint) -- never invents a generic one.
#   - atoms-lint GATE before staging: a HARD lint failure refuses the whole save; advisory notes
#     print but never block. Mirrors session-autosave's write-path gate (see step 3).
#   - VERIFIES THE ARTIFACT after push: fetch, then confirm HEAD is contained in origin/main.
#     Never trusts the push command's own exit line.
#   - dr-check at the end is ADVISORY only; it never gates the save (a stale project repo or a
#     behind-count must not make a clean canon save look failed).
#
# Usage:
#   bash setup/canon-save.sh "subject line"
#   bash setup/canon-save.sh "subject" "" "body line 1" "body line 2"   # a blank arg = a blank line
#   bash setup/canon-save.sh            # uses the .git/autosave-msg hint if present, else errors
#
set -euo pipefail

REPO="${HOME}/Claude-Memory"
HINT="${REPO}/.git/autosave-msg"
cd "${REPO}"

die() { printf '\n[canon-save] FAILED: %s\n' "$*" >&2; exit 1; }

# --- 1. Refuse mid-operation states (mirror session-autosave bailout; fail loud, not open) -------
GITDIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || die "not a git repo at ${REPO}"
if git rev-parse --verify --quiet MERGE_HEAD        >/dev/null 2>&1 \
 || git rev-parse --verify --quiet CHERRY_PICK_HEAD >/dev/null 2>&1 \
 || git rev-parse --verify --quiet REVERT_HEAD      >/dev/null 2>&1 \
 || [ -d "${GITDIR}/rebase-merge" ] || [ -d "${GITDIR}/rebase-apply" ] \
 || [ -n "$(git ls-files -u)" ]; then
  die "repo is mid-operation (rebase/merge/cherry-pick/revert or unmerged index). Resolve by hand first; nothing was staged, committed, or pushed."
fi
BRANCH="$(git symbolic-ref --short -q HEAD || true)"
[ "${BRANCH}" = "main" ] || die "HEAD is '${BRANCH}', not main. Refusing."

# --- 2. Resolve the authored commit message (never invent a generic one) -------------------------
MSGFILE="$(mktemp)"
trap 'rm -f "${MSGFILE}"' EXIT
if [ "$#" -gt 0 ]; then
  printf '%s\n' "$@" > "${MSGFILE}"
elif [ -s "${HINT}" ]; then
  cat "${HINT}" > "${MSGFILE}"
fi

# --- 3. ATOMS-LINT GATE -- refuse a HARD failure before anything is staged -----------------------
#     WHY: if only the Stop-hook autosave lints, a malformed atom can ride THIS path to origin and
#     reach every machine before dr-check catches it after the fact -- hardening in one save path
#     but not the other (STANDARDS 2A). Interpreter detection + exit handling mirror session-autosave
#     (any non-zero = fail, incl. a lint crash -> fail closed; no python -> proceed, but LOUDLY here).
#     Differences, both deliberate: (a) autosave holds back just the implicated files and commits the
#     rest because nobody watches a Stop hook -- this is the foreground path, so refuse the WHOLE save
#     and let the person at the keyboard fix it; (b) lint whenever there is anything to commit OR
#     push, not only when atoms.jsonl is staged, since a .md edit alone can create a dangling ref and
#     an ahead-only push can carry a bad atom committed by hand. Runs on the working tree (= exactly
#     what `git add -A` stages next), BEFORE staging, so a refusal leaves the index untouched.
DIRTY="$(git status --porcelain)"
PRE_AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
if [ -n "${DIRTY}" ] || [ "${PRE_AHEAD}" -gt 0 ]; then
  APY=""
  for c in "py -3" python3 python; do
    if $c -c "import sys" >/dev/null 2>&1; then APY="$c"; break; fi
  done
  if [ -z "${APY}" ]; then
    echo "[canon-save] WARNING: no working python -- atoms-lint SKIPPED; memory/atoms.jsonl is NOT validated by this save." >&2
  else
    echo "[canon-save] atoms-lint (HARD failures block; '?' advisories do not) ..."
    $APY "${REPO}/setup/atoms-lint.py" "${REPO}/memory/atoms.jsonl" \
      || { rc=$?; die "atoms-lint exit ${rc}: HARD failure(s) listed above (malformed/duplicate id, bad field, unresolved src, dangling ref, boot budget) or the lint itself crashed. A bad atom must not reach your other machines. NOTHING was staged, committed, or pushed. Fix it (py -3 setup/atoms-lint.py), then re-run."; }
  fi
fi

# --- 4. Stage everything; show exactly what will land -------------------------------------------
git add -A
if git diff --cached --quiet; then
  echo "[canon-save] nothing new to commit."
  COMMITTED=0
else
  [ -s "${MSGFILE}" ] || die "changes are staged but NO authored message was given. Pass a subject arg, or set one via setup/next-commit.sh. Refusing to invent a generic message in the foreground path."
  echo "[canon-save] staging:"
  git diff --cached --stat
  git commit -F "${MSGFILE}"
  rm -f "${HINT}"    # consumed here so the Stop-hook autosave cannot reuse it
  COMMITTED=1
fi

# --- 5. Nothing to commit AND nothing unpushed => done ------------------------------------------
AHEAD="$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
if [ "${COMMITTED}" -eq 0 ] && [ "${AHEAD}" -eq 0 ]; then
  echo "[canon-save] tree clean and 0 unpushed. Nothing to do."
  exit 0
fi

# --- 6. Pull-first (rebase), then push -- NO PIPES, fail loud -----------------------------------
echo "[canon-save] pull --rebase origin main ..."
if ! git pull --rebase origin main; then
  die "pull --rebase failed (most likely a conflict). Repo left as-is for you to resolve; NOTHING was pushed. Finish the rebase, then re-run."
fi
echo "[canon-save] push origin main ..."
git push origin main || die "push REJECTED. Your commit is LOCAL ONLY -- it is NOT in canon. Re-run after reconciling (origin moved)."

# --- 7. VERIFY THE ARTIFACT: HEAD must be contained in origin/main ------------------------------
#     Ancestor test (not strict ==) so a concurrent pusher landing AFTER us is not a false alarm:
#     what we assert is that OUR commit actually reached canon, tolerant of later commits.
git fetch --quiet origin
if git merge-base --is-ancestor HEAD origin/main; then
  echo "[canon-save] VERIFIED in canon: HEAD $(git rev-parse --short HEAD) is contained in origin/main."
  git log -1 --oneline
else
  die "post-push verify: local HEAD is NOT contained in origin/main -- the push did not land. Do NOT trust this as saved."
fi

# --- 8. dr-check (advisory only -- does NOT gate the save) --------------------------------------
echo "[canon-save] dr-check (advisory) ..."
bash setup/dr-check.sh 2>&1 | tail -6 || true

echo "[canon-save] done -- canon is current."
