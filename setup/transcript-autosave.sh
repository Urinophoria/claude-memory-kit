#!/usr/bin/env bash
# transcript-autosave.sh — keep transcripts/ current, automatically.
#
# Claude Code writes every session verbatim to ~/.claude/projects/<slug>/<id>.jsonl,
# OUTSIDE this repo. Nothing backed those up. This hook folds them in:
#   raw   -> transcripts/raw/*.jsonl.gz   (gitignored, local; full tool output)
#   render-> transcripts/rendered/*.md    (tracked; conversation only, redacted)
# See transcripts/README.md for why those are two different risk tiers.
#
# Wired on SessionStart + SessionEnd, deliberately NOT on Stop:
#   Stop fires every TURN. Rendering there would dirty the tree constantly and the
#   session-autosave Stop hook would turn every turn into a commit — exactly the commit
#   noise STANDARDS §3 exists to prevent. Session boundaries give the same guarantee
#   without the churn.
#   SessionEnd is the normal path. SessionStart is the net: if a session is killed
#   rather than ended, the next one picks it up. Same belt-and-suspenders posture as
#   check-canon/session-autosave.
#
# Conservative, like session-autosave.sh: no-op when nothing changed, commits ONLY
# transcripts/rendered (never sweeps unrelated work), fast-forward push only, never
# rebases or merges, and always exits 0 so a hiccup can't block a session.

REPO="${HOME}/Claude-Memory"
TOOL="${REPO}/transcripts/render-session.py"
[ -d "${REPO}/.git" ] || exit 0
[ -f "${TOOL}" ] || exit 0

# The Windows `py` launcher first; python3 on Linux. Bare `python` is deliberately last —
# on Windows it's usually the Microsoft Store stub that exits non-zero.
PY=""
for c in py python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" --version >/dev/null 2>&1; then
        PY="$c"; break
    fi
done
[ -n "${PY}" ] || exit 0

# --project ALL: the project-dir slug is derived from the repo's absolute path, so it
# differs per machine (one machine vs. another). ALL matches every dir that
# actually holds transcripts, so this file works unchanged everywhere.
"${PY}" "${TOOL}" archive --project ALL --quiet 2>/dev/null
"${PY}" "${TOOL}" render --all --project ALL -o "${REPO}/transcripts/rendered" \
        --redact --quiet 2>/dev/null

# Second copy of the raw tier, which git deliberately does not hold. Verifies gzip CRCs on
# arrival — a machine can have flaky RAM, so an unverified backup made there isn't worth much.
#
# ⚠️ VISIBILITY FIX (a machine, 2026-07-30). This used to be `mirror --quiet 2>/dev/null`
# unconditionally, which made three different outcomes look identical: mirrored fine, no target
# configured, and TARGET CONFIGURED BUT UNREACHABLE. That last one is the dangerous one — you
# believe the raw tier has a second copy and it does not. Same defect class as this hook silently
# exiting when no interpreter was found (which is how a machine can silently stop archiving), and as
# dr-check never testing for "behind".
#
# So: stay silent when NO target is configured (most machines — nothing to say), but report loudly
# when a target IS configured and the mirror could not complete. A backup you cannot confirm is
# not a backup.
if [ -f "${REPO}/transcripts/mirror-target.txt" ]; then
    if ! "${PY}" "${TOOL}" mirror 2>&1; then
        echo "⚠️  transcript mirror FAILED — the raw tier has no verified second copy." >&2
    fi
else
    "${PY}" "${TOOL}" mirror --quiet 2>/dev/null
fi

# SELECTIVE DRIFT to a second, narrower target (optional). mirror-target.txt takes everything;
# drift-target.txt (gitignored, per machine) takes only the sessions transcripts/drift-policy.txt clears
# (no sensitive record content entered Claude's context, quiet `settle` hours) -- for when one archive may
# hold everything but another (a personal NAS, a shared drive) may not.
# Absent file = off. Same visibility rule as the mirror: configured-but-failing is LOUD; quiet mode
# still prints any HELD session found already on the target (you remove it; this never deletes).
if [ -f "${REPO}/transcripts/drift-target.txt" ]; then
    if ! "${PY}" "${TOOL}" drift --quiet 2>&1; then
        echo "⚠️  transcript drift FAILED — policy-cleared sessions did not reach the drift target." >&2
    fi
fi

# Nothing new to say? Stay invisible.
[ -n "$(git -C "${REPO}" status --porcelain -- transcripts/rendered)" ] || exit 0

# ── SAFETY BAILOUT (2026-08-26, T1) ───────────────────────────────────────────────────────────
# Same rule as session-autosave.sh: never commit while the repo is mid-operation. Committing the
# rendered/ changes onto a paused rebase/merge (or a HEAD that isn't main) would land them on the
# wrong base or entangle them with an in-progress resolution. The render above already ran (harmless
# — it just writes files); we skip only the COMMIT until the human finishes. Rendered stays dirty
# and lands on the next clean boundary. (git already refuses to commit an unmerged index, but a
# rebase-in-progress with a clean index would otherwise slip through — this closes that.)
GITDIR=$(git -C "${REPO}" rev-parse --absolute-git-dir 2>/dev/null)
if git -C "${REPO}" rev-parse --verify --quiet MERGE_HEAD        >/dev/null 2>&1 \
 || git -C "${REPO}" rev-parse --verify --quiet CHERRY_PICK_HEAD >/dev/null 2>&1 \
 || git -C "${REPO}" rev-parse --verify --quiet REVERT_HEAD      >/dev/null 2>&1 \
 || { [ -n "${GITDIR}" ] && { [ -d "${GITDIR}/rebase-merge" ] || [ -d "${GITDIR}/rebase-apply" ]; }; } \
 || [ -n "$(git -C "${REPO}" ls-files -u 2>/dev/null)" ] \
 || [ "$(git -C "${REPO}" symbolic-ref --short -q HEAD 2>/dev/null)" != "main" ]; then
  echo "transcript-autosave: repo mid-operation or not on main — rendered/ left dirty, will commit on the next clean boundary." >&2
  # Drop the HELD marker too (pass-2 #2) so a killed mid-rebase session is announced next SessionStart.
  # session-autosave (the every-turn Stop hook) clears it once the repo is back to a normal state.
  printf 'autosave HELD %s — repo is mid-operation (rebase/merge/conflict) or off main. Uncommitted work is NOT backed up on this box. Finish the operation, then let autosave run.\n' \
    "$(date '+%Y-%m-%d %H:%M')" > "${REPO}/.git/autosave-HELD"
  exit 0
fi

# ── FAIL-CLOSED SECRET GATE (2026-08-26, T2) ──────────────────────────────────────────────────
# `render --redact` above masks known secret shapes, but redaction is pattern-based and cannot be
# perfect. Before committing (and auto-PUSHING to GitHub), re-scan the rendered/ tree WITHOUT
# --redact: `scan` exits non-zero iff a HOT secret is still present in the .md we're about to ship.
# If so, do NOT commit — leave rendered/ dirty for review rather than push a credential. The next
# boundary re-renders + re-scans, so a transient miss self-clears; a real one keeps failing loudly
# until a human looks. This is the belt to the scanner's suspenders (2026-08-24 sweep, #1 critical).
SCAN_RC=0; "${PY}" "${TOOL}" scan "${REPO}/transcripts/rendered" >/dev/null 2>&1 || SCAN_RC=$?
if [ "${SCAN_RC}" -ne 0 ]; then
  # rc 1 = a HOT hit; rc 2 = a file the scan could not read (a scan crash used to read as a secret).
  if [ "${SCAN_RC}" = 2 ]; then
    echo "⚠️  transcript-autosave: the secret scan could NOT READ a file in transcripts/rendered — NOT committing/pushing. Its UNREADABLE line names it (a stray directory named *.md, a locked file, an over-long path): ${PY} transcripts/render-session.py scan transcripts/rendered" >&2
  else
    echo "⚠️  transcript-autosave: a possible secret SURVIVED redaction in transcripts/rendered (scan rc ${SCAN_RC}) — NOT committing/pushing. Review: ${PY} transcripts/render-session.py scan transcripts/rendered" >&2
  fi
  exit 0
fi

git -C "${REPO}" add -- transcripts/rendered
git -C "${REPO}" \
    commit -q -m "auto: transcript archive $(date '+%Y-%m-%d %H:%M') (session boundary)" \
    2>/dev/null

# Honor session-autosave's atoms-lint gate: PUSH WITHHELD means HEAD fails atoms-lint AND carries
# local-only commits, so pushing HEAD here would ship exactly what that gate held (2026-09-30). The
# rendered commit stays local; it rides the next push once the tip lints clean.
grep -q 'PUSH WITHHELD' "${REPO}/.git/atoms-lint-FAILED" 2>/dev/null && exit 0

# Non-fast-forward reject (origin moved) is benign and self-heals via the next pull-first; an
# ahead-only unpushed state is surfaced by check-canon next session. Nothing lost either way.
git -C "${REPO}" push -q origin main 2>/dev/null || true

exit 0
