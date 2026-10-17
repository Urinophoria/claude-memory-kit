#!/usr/bin/env bash
# check-canon.sh — SessionStart canon check (STANDARDS §2 "PULL FIRST").
#
# Fetches origin for the Claude-Memory repo and WARNS (via SessionStart additionalContext)
# if local is BEHIND origin/main. FETCH-AND-WARN ONLY — it never merges, pulls, or touches
# the working tree, so it can't surprise-clobber local work. Wired as a SessionStart hook in
# .claude/settings.json. Travels to every machine via git; the repo is always ~/Claude-Memory.
#
# Output: JSON on stdout with hookSpecificOutput.additionalContext (only when there's something
# to say); silent + exit 0 on the fully-healthy happy path, so it's invisible then.
#
# FAIL-LOUD (2026-08-26, T1 of the memory-system sweep). This hook used to `|| exit 0` on any
# fetch failure — which made an unreachable origin (expired token, DNS, captive portal, renamed
# remote) look identical to "current", so a box with broken git silently read stale canon forever.
# It also only ever warned when BEHIND, so a failed autosave push that left commits UNPUSHED (ahead
# only) was invisible. Now it reports THREE freshness faults, plus any backstop-failure marker the
# Stop/SessionEnd autosave left behind (those hooks can't reliably surface their own stdout, so they
# drop a marker in .git/ and THIS hook — whose stdout IS injected into the session — announces it).

REPO="${HOME}/Claude-Memory"
FAILMARK="${REPO}/.git/autosave-FAILED"
HELDMARK="${REPO}/.git/autosave-HELD"
ATOMSMARK="${REPO}/.git/atoms-lint-FAILED"
[ -d "${REPO}/.git" ] || exit 0

# Freshness vs origin. If fetch FAILS, say so loudly (don't fall silent) and still judge against
# whatever (possibly stale) refs we already have — an already-known "behind" must still warn.
fetchmsg=""
if ! git -C "${REPO}" fetch -q origin 2>/dev/null; then
  fetchmsg="canon freshness UNVERIFIED — 'git fetch' FAILED (auth/network/renamed-remote?). The check below is vs possibly-stale local refs, and your pushes may also be failing. Verify connectivity to origin before trusting or writing canon."
fi

behind=$(git -C "${REPO}" rev-list --count HEAD..origin/main 2>/dev/null)
ahead=$(git -C "${REPO}" rev-list --count origin/main..HEAD 2>/dev/null)
freshmsg=""
if [ "${behind:-0}" -gt 0 ] 2>/dev/null; then
  freshmsg="Claude-Memory is ${behind} commit(s) BEHIND origin/main"
  if [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then
    freshmsg="${freshmsg} and ${ahead} AHEAD (diverged)"
  fi
  freshmsg="${freshmsg}. PULL FIRST per STANDARDS section 2 — run 'git fetch && git rebase origin/main' on the memory repo (and any project repo you will touch) BEFORE any work or push."
elif [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then
  # ahead-only = local commits never reached origin (a previous autosave push likely failed).
  freshmsg="Claude-Memory has ${ahead} local commit(s) NOT on origin/main — a previous autosave push may have failed. Run 'git push origin main' (after a 'git fetch' to confirm you're not also behind)."
fi

# Backstop-failure marker from a previous Stop/SessionEnd autosave (see session-autosave.sh).
markmsg=""
if [ -f "${FAILMARK}" ]; then
  reason=$(tr -d '\r\n"\\' < "${FAILMARK}" 2>/dev/null | cut -c1-300)
  markmsg="AUTOSAVE BACKSTOP FAILED on this box (canon may not be saving): ${reason}. Check 'cd ~/Claude-Memory && git status' — a stale .git/index.lock or a blocked commit is the usual cause. Clears automatically on the next successful autosave."
fi

# HELD marker: a previous Stop/SessionEnd bailed because the repo was mid-operation (paused rebase/
# merge). Uncommitted work on this box is NOT backed up until the operation is finished.
heldmsg=""
if [ -f "${HELDMARK}" ]; then
  hreason=$(tr -d '\r\n"\\' < "${HELDMARK}" 2>/dev/null | cut -c1-300)
  heldmsg="AUTOSAVE HELD on this box — a previous session bailed mid-operation: ${hreason}. FINISH the rebase/merge (or 'git rebase --abort'), then commit — uncommitted work here is not backed up yet. Clears automatically once the repo is back to a normal state."
fi

# ATOMS marker: a previous Stop autosave's atoms-lint gate fired (a bad atom or a DANGLING atom ref must
# not auto-push to other machines). Since 2026-09-30 it lints whatever is staged, not just atoms.jsonl, so the
# held-back files can be any .md; the marker names them, and says if the push itself was WITHHELD. The
# rest of that session's work DID commit; only the named files are stranded, dirty, until fixed.
atomsmsg=""
if [ -f "${ATOMSMARK}" ]; then
  areason=$(tr -d '\r\n"\\' < "${ATOMSMARK}" 2>/dev/null | cut -c1-1200)
  atomsmsg="ATOMS-LINT GATE fired on this box (a bad atom / dangling atom ref must not reach other machines): ${areason} If it says PUSH WITHHELD, do NOT raw-push the ahead commits: fix the lint, then canon-save."
fi

# Assemble (fetch-failure, then freshness, then markers) into one additionalContext string.
msg=""
for p in "${fetchmsg}" "${freshmsg}" "${markmsg}" "${heldmsg}" "${atomsmsg}"; do
  [ -n "$p" ] || continue
  if [ -z "$msg" ]; then msg="$p"; else msg="${msg}  ||  ${p}"; fi
done

if [ -n "${msg}" ]; then
  # escape backslashes and double-quotes so the string is valid inside the JSON below
  esc=$(printf '%s' "${msg}" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "${esc}"
fi
exit 0
