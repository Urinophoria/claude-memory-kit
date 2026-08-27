---
name: load-memory
description: >
  Load the user's persistent cross-session, cross-machine memory. Use immediately at the start of
  ANY session, when switching machines, or when the user says "load my memory", "get up to speed",
  "what were we working on", "pick up where we left off", "new computer". Also use at session end
  when the user says "save memory", "save what we did", "update my notes". This is the boot
  sequence for the memory system.
---

# Load Memory

Persistent memory for the user, git-managed at `~/Claude-Memory`. Works in Claude Code and Cowork.

## 🛑 Two hard rules

### 1. You are not the only Claude running
Sessions on the same account are NOT aware of each other and can edit the same files with no locking.
**Commit early; pull --rebase before you write and again before you push.** An uncommitted edit is one
stale write away from gone. If another session may be open, say so and reconcile before writing.

### 2. Be aware of EVERYTHING, deep-read on demand
The user runs many things at once; loading only "the most recent thing" loses context. But the corpus
can outgrow a full read, so: **read the index tables in full every session** (`MEMORY.md`,
`code/INDEX.md`, `cowork/INDEX.md` — they summarize everything), read the **core** memory files, and
**deep-read a specific `PROJECT.md`/`SESSION.md`/topic `.md` when the task reaches it**. Never work from
a hardcoded file list; never substitute "the newest file" for the thread the request actually needs.

---

## LOAD mode (start of session / new machine)

1. **Claude Code:** the repo is the working dir. **`git pull --rebase` before reading anything.**
   **Cowork:** ask the user to connect the `Claude-Memory` folder (Cowork has no shell — it can't pull or
   commit, so prefer additive writes and tell the user changes are uncommitted).
2. **Read the core, in order:** `MEMORY.md` (index + ⏩ ACTIVE SESSION HANDOFF), `STANDARDS.md`,
   `~/.claude/CLAUDE.md` (who the user is), `memory/*` core files. Then **enumerate `memory/`** so you know
   what every file is (the index gives one-line summaries) and deep-read any the task touches.
3. **Read both index tables** (`code/INDEX.md`, `cowork/INDEX.md`) in full; deep-read the `PROJECT.md` /
   `SESSION.md` the request or the handoff points at.
4. **State machine identity + freshness out loud** so the user can catch a mistake early:
   `Machine: <name> · <Claude Code|Cowork> · canon: <in sync | N behind>`. If canon is behind, PULL FIRST.
5. **Run `bash setup/dr-check.sh`** and report the result — it catches index-tree holes and unpushed work
   that reading alone misses.
6. **Confirm ready:** machine, handoff (found/dated or none), dr-check verdict, anything surfaced as
   surface-every-session, active work newest-first, gaps you couldn't resolve. Then ask what to work on.

## SAVE mode (end of session / good stopping point)

1. **`git pull --rebase` first** — another session may have pushed.
2. **Write back every layer the work touched** (STANDARDS §3 — the index tree moves as one): the project
   repo → `code/<name>/PROJECT.md` → `code/INDEX.md` row → `MEMORY.md` row; `memory/*.md` for durable
   facts/decisions; an atom in `atoms.jsonl` for anything that should surface every session (same session
   as its source file).
3. **Rewrite the ⏩ ACTIVE SESSION HANDOFF** in `MEMORY.md` — what you were doing, state, the single next
   action, blockers. Replace it wholesale; date it. This is the slot a new machine reads first.
4. **Commit + push, same session:** `git add -A && git commit -m "…" && git pull --rebase && git push`.
   Then `bash setup/dr-check.sh` — GREEN before you stop. (Cowork can't do this — tell the user the writes
   are uncommitted and need a Claude Code session to reach canon.)

## MIGRATE mode (one-time per machine, optional)
Scan the machine for session outputs / code projects not yet in canon, draft `SESSION.md`/`PROJECT.md`,
confirm with the user, then commit + push. After it runs once, SAVE → push → LOAD carries everything.

---
## Related
`STANDARDS.md` (the rules) · `setup/dr-check.sh` (the acceptance test) · `memory/atoms.README.md`
(the fast-fact layer).
