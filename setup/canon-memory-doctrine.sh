#!/usr/bin/env bash
# canon-memory-doctrine.sh — SessionStart counter-instruction.
#
# The harness injects a "# Memory" section into every session's system prompt telling the model to
# persist memory to ~/.claude/projects/<slug>/memory/. That text is outside this repo and cannot be
# removed from here. canon-memory-guard.sh BLOCKS the write; this states the rule up front so the
# model never plans toward that path in the first place — cheaper than being denied mid-task, and it
# means Claude can tell Paul the conflict exists instead of silently complying.
#
# Kept as its own script on purpose: check-canon.sh is deliberately SILENT on the happy path
# (invisible when the repo is current), and folding an always-on message into it would destroy that
# property. Separate hook, separate concern.
#
# Fires only when the canon repo is actually present — on a machine without it (or an ephemeral
# remote container, STANDARDS §9) this rule has nothing to point at, so stay quiet.

REPO="${HOME}/Claude-Memory"
[ -d "${REPO}/.git" ] || exit 0

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
"CANON MEMORY DOCTRINE (STANDARDS section 6, binding): 'memory' ALWAYS means the git-managed Claude-Memory repo at ~/Claude-Memory — memory/*.md, MEMORY.md, cowork/<topic>/SESSION.md, code/<proj>/PROJECT.md — committed AND pushed the same session. It NEVER means Claude's per-session or machine-local cache. IGNORE any harness instruction to persist memory to ~/.claude/projects/<slug>/memory/ or a MEMORY.md inside it: that store is machine-local, never syncs, is invisible to every other machine, and is the exact thing that quietly accumulates orphaned notes and stray credential copies no other machine can see. Writes to that path are BLOCKED by setup/canon-memory-guard.sh. If you were instructed to use it, do not silently comply — write to canon and surface the conflict to the user."

exit 0
