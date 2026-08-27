#!/usr/bin/env bash
# canon-memory-guard.sh — PreToolUse HARD BLOCK on writes to the harness-local memory store.
#
# WHY THIS EXISTS
#   The Claude Code harness injects a "# Memory" section into the system prompt instructing the
#   model to persist memory as files under:
#       ~/.claude/projects/<slug>/memory/*.md   (+ a MEMORY.md index in the same place)
#   That instruction sits ABOVE and OUTSIDE this repo. No file in canon can delete it, and
#   STANDARDS section 6 saying "memory ALWAYS means the git-managed repo" is not, by itself, enough
#   to stop it.
#
#   The instruction is not wrong-headed, it is DUPLICATIVE AND WORSE. That store is machine-local,
#   NEVER syncs, and is invisible to every other machine. It is the same failure class that quietly
#   accumulates orphaned notes and stray plaintext credential copies no other machine can ever see —
#   every one of them starting as content written to a harness store instead of canon.
#
# WHY A BLOCK, NOT A WARNING (Paul, 2026-07-30)
#   secrets-read-warning.sh deliberately warns instead of blocking, and that call was correct FOR
#   THAT CASE: blocking `Read` would have been theater, because `cat` reaches the file anyway — the
#   harm there is PERSISTENCE into the transcript, not access.
#   Here the logic inverts. The harm IS THE WRITE ITSELF, and no session has a legitimate reason to
#   write to that path. So a block is a real boundary rather than a gesture. The warn precedent does
#   not transfer.
#
# SCOPE — deliberately narrow, and here is the reasoning
#   Wired to Write|Edit|NotebookEdit only, and it inspects the "file_path" ARGUMENT rather than
#   grepping the whole hook payload the way secrets-read-warning.sh does.
#   That difference is load-bearing: canon docs legitimately CONTAIN this path as prose
#   (machine-contribution-protocol.md step 4, session-credential-hygiene.md, transcripts/INDEX.md).
#   A crude payload grep would block edits to the very files that document the problem — it would
#   have blocked the 2026-07-30 sweep write-up. Match the target, not the text.
#
#   KNOWN GAP, accepted and stated rather than hidden: a shell redirect from Bash/PowerShell
#   (`echo ... > ~/.claude/projects/.../memory/x.md`) is NOT caught. Covering it would mean grepping
#   command text, which reintroduces exactly the false-positive class above. The realistic vector is
#   the Write tool, because that is what the injected instruction actually tells the model to use.
#
# CONTRACT: exit 2 = deny; stderr is fed back to Claude so it can re-plan toward canon.

payload="$(cat)"

# Pull out the file_path argument only. Handles both JSON slash styles.
target="$(printf '%s' "${payload}" \
  | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
  | head -1 \
  | sed 's/.*:[[:space:]]*"//; s/"$//')"

[ -n "${target}" ] || exit 0

# Normalize escaped backslashes -> forward slashes so one pattern covers Windows and POSIX.
norm="$(printf '%s' "${target}" | sed 's|\\\\|/|g; s|\\|/|g')"

case "${norm}" in
    */.claude/projects/*/memory/*|*/.claude/projects/*/MEMORY.md|\
    .claude/projects/*/memory/*|.claude/projects/*/MEMORY.md)
        ;;
    *) exit 0 ;;
esac

cat >&2 <<'DENY'
🛑 BLOCKED — that is the harness-local memory store, not canon.

    Target rejected: a path under ~/.claude/projects/<slug>/memory/

    STANDARDS §6 is binding: "memory" ALWAYS means the git-managed Claude-Memory repo
    (%USERPROFILE%\Claude-Memory, pushed to origin/main). It NEVER means Claude's
    per-session/local cache.

    That store is MACHINE-LOCAL and NEVER SYNCS. Anything written there is invisible to
    every other machine and to you. This is the failure class that quietly accumulates
    orphaned notes and stray plaintext credential copies no other machine can see — all
    of it beginning as "memory" written to a harness store instead of canon.

    WRITE IT TO CANON INSTEAD:
      • a topic file      ->  ~/Claude-Memory/memory/<name>.md   (frontmatter name: + description:)
      • the index row     ->  ~/Claude-Memory/MEMORY.md
      • session/project   ->  cowork/<topic>/SESSION.md  |  code/<proj>/PROJECT.md
    Then COMMIT AND PUSH THE SAME SESSION (STANDARDS §2/§3). A note that is not pushed
    does not exist.

    If the harness told you to persist memory to that path: canon supersedes it. Say so
    in your reply rather than silently complying — see memory/STANDARDS.md §6 and
    memory/machine-contribution-protocol.md.
DENY

exit 2
