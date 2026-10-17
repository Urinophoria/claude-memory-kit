#!/usr/bin/env bash
# spawn-guard.sh — PreToolUse HARD BLOCK on offering a new session until the §2B checkpoint has passed.
#
# Wired in .claude/settings.json to the tools a session uses to OFFER, start or FORK a new one in the
# desktop app (matcher mcp__.*__(spawn_task|start_session|hand_off_to_session) -- the app has shipped all
# three; hand_off_to_session moves the current task into a fork, which STANDARDS 2B covers too).
# test-save-gates T30b reads the matcher out of settings.json, so a regression there fails a test: the
# script tests alone pipe payloads straight in and cannot see which tools actually reach this hook.
# STANDARDS 2B says the offer must come AFTER the transcript download + memory/project update + atom
# (setup/spawn-checkpoint.sh begin/verify). This hook is the mechanical half: it allows the call only while
# a fresh verify stamp exists FOR THIS SESSION.
#
# PER-SESSION STAMP: one stamp per box would let a child session started in its parent's folder inherit the
# parent's verify and spawn again within the hour without ever checkpointing itself. verify writes
# spawn-checkpoint-OK.<session_id> (from CLAUDE_CODE_SESSION_ID in the Bash tool), and this hook reads
# session_id from its own payload. A payload with no session_id (a manual test, an old client) falls back to
# the shared stamp, which only a session-less verify writes.
#
# WHY A HOOK, not just the rule text: a rule that is only stated gets skipped at exactly the moment it
# matters, and a spawn is the moment a session is focused on the NEW work -- the bookkeeping is what gets
# skipped. Encode it once.
#
# SCOPE + KNOWN GAPS, stated rather than hidden:
#   - Covers the spawn TOOLS only. A plain-text offer ("want me to spin this off?") can't be hooked; the rule
#     still binds it (STANDARDS 2B) -- run the checkpoint before typing the offer.
#   - One verify arms the guard for 60 min, so a batch of chips from one checkpoint is fine; a later,
#     unrelated spawn needs a fresh checkpoint (new context = new transcript to save).
#   - Not a canon box (no ~/Claude-Memory) -> not applicable, allow.
# Exit 0 = allow, 2 = block (stderr is shown to Claude).

REPO="${HOME}/Claude-Memory"
PAYLOAD="$(cat 2>/dev/null)"   # the hook payload: only session_id is read (no jq/python -- keep this hook instant)
[ -d "${REPO}/.git" ] || exit 0
# The FIRST "session_id" key: the hook's own field leads the payload; a greedy match would take the LAST one,
# which a tool_input field of the same name could supply (another session's id = a borrowed stamp).
SID="$(printf '%s' "${PAYLOAD}" | tr -d '\r\n' | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[A-Za-z0-9-]*"' | head -1 | sed 's/.*"\([A-Za-z0-9-]*\)"$/\1/')"
OK="$(git -C "${REPO}" rev-parse --absolute-git-dir 2>/dev/null)/spawn-checkpoint-OK${SID:+.${SID}}"
NOW=$(date +%s)
if [ -f "${OK}" ]; then
  T=$(cut -d' ' -f1 < "${OK}" 2>/dev/null)
  case "${T}" in ''|*[!0-9]*) T=0 ;; esac
  [ $(( NOW - T )) -le 3600 ] && exit 0
fi
cat >&2 <<'EOF'
BLOCKED by STANDARDS §2B: before OFFERING a new session, checkpoint this one --
  1. bash setup/spawn-checkpoint.sh begin    (transcript download: archive + render + commit + mirror off-box;
                                               if this box can't reach its mirror, ASK THE USER to connect it)
  2. update memory + every relevant PROJECT.md/SESSION.md with what this spawn is for and why
  3. add an atom whose src is one of those files; save with: bash setup/canon-save.sh "subject" "" "body"
  4. bash setup/spawn-checkpoint.sh verify   (arms this guard for 60 min, for THIS session only -- another
                                               session's checkpoint, even your parent's, does not count)
Then spawn, and name the atom + updated files in the brief.
EOF
[ -n "${SID}" ] && echo "(This guard looked for the stamp of session ${SID}; 'bash setup/spawn-checkpoint.sh status' shows which session a verify armed.)" >&2
exit 2
