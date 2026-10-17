#!/usr/bin/env bash
# spawn-guard.sh — PreToolUse HARD BLOCK on offering a new session until the §2B checkpoint has passed.
#
# Wired in .claude/settings.json to the tools a session uses to OFFER or start a new one in the desktop
# app (matcher mcp__.*__(spawn_task|start_session) -- the app has shipped both names). STANDARDS 2B says
# that offer must come AFTER the transcript download + memory/project update + atom
# (setup/spawn-checkpoint.sh begin/verify).
# This hook is the mechanical half: it allows the call only while a fresh verify stamp exists.
#
# WHY A HOOK, not just the rule text: a rule that is only stated gets skipped at exactly the moment it
# matters, and a spawn is the moment a session is focused on the NEW work -- the bookkeeping is what gets
# skipped. Encode it once.
#
# SCOPE + KNOWN GAPS, stated rather than hidden:
#   - Covers the spawn TOOL only. A plain-text offer ("want me to spin this off?") can't be hooked; the rule
#     still binds it (STANDARDS 2B) -- run the checkpoint before typing the offer.
#   - One verify arms the guard for 60 min, so a batch of chips from one checkpoint is fine; a later,
#     unrelated spawn needs a fresh checkpoint (new context = new transcript to save).
#   - Not a canon box (no ~/Claude-Memory) -> not applicable, allow.
# Exit 0 = allow, 2 = block (stderr is shown to Claude).

REPO="${HOME}/Claude-Memory"
cat > /dev/null 2>&1   # drain the hook payload; the decision doesn't depend on it
[ -d "${REPO}/.git" ] || exit 0
OK="$(git -C "${REPO}" rev-parse --absolute-git-dir 2>/dev/null)/spawn-checkpoint-OK"
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
  4. bash setup/spawn-checkpoint.sh verify   (arms this guard for 60 min)
Then spawn, and name the atom + updated files in the brief.
EOF
exit 2
