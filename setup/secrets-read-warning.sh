#!/usr/bin/env bash
# secrets-read-warning.sh — PreToolUse WARNING (not a block) when a tool call touches
# SECRETS.local.md.
#
# Why warn and not block (Paul's call, 2026-07-26, and it holds up on the logic):
#   This was never a trust boundary. Blocking `Read` would not deny Claude the file —
#   `cat` from Bash reaches it just the same. What the control actually prevents is
#   PERSISTENCE: a tool result carrying those credentials gets written verbatim to
#   ~/.claude/projects/<slug>/*.jsonl, in plaintext, forever, on whatever machine ran
#   the session. That artifact appears regardless of anyone's intentions. So the useful
#   control is one that makes the moment VISIBLE, not one that pretends to gate access
#   it can't gate.
#   See memory/session-credential-hygiene.md. Revisit block-vs-warn when Paul has
#   processed it; flipping this to a block is a one-line change (see bottom).
#
# Deliberately crude matching: greps the raw hook payload for the filename rather than
# parsing JSON (no jq dependency, works identically on every machine). That over-triggers
# — editing .gitignore will set it off — and that's the correct trade for a warning.
# Over-triggering costs a line of output; under-triggering costs a credential.

payload="$(cat)"

case "${payload}" in
    *SECRETS.local.md*) ;;
    *) exit 0 ;;
esac

# stderr: human-readable, shows up in the hook's output surface.
cat >&2 <<'WARN'
⚠️  SECRETS.local.md is in this tool call.

    If the tool RETURNS its contents, they are written verbatim and in plaintext to this
    session's transcript (~/.claude/projects/<slug>/*.jsonl) — permanently, on this
    machine. Compaction does not remove it; the .jsonl is written first.

    Prefer: leave the placeholder (<PFX_PW>) in Claude's context and let the COMMAND
    source the real value at runtime, so it never renders into a tool result.
    A command that echoes the value is exactly as bad as a Read.

    Not blocked. This is a warning by design — see memory/session-credential-hygiene.md.
WARN

# stdout: structured, so the warning also reaches Claude's context rather than only the
# user's screen. Claude should re-plan toward the placeholder route when it sees this.
cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "additionalContext": "WARNING: this tool call touches memory/SECRETS.local.md. If the result carries real credential values they will be written in plaintext to this session's transcript, permanently. Do not read the file to learn a secret. Keep the <PLACEHOLDER> in context and have the command source the value at runtime instead; a command that echoes the value is equally bad. If Paul explicitly asked for this, proceed and tell him it is being recorded. See memory/session-credential-hygiene.md."
  }
}
JSON

# To make this a hard block instead: exit 2 here (exit 2 = deny, stderr goes to Claude).
exit 0
