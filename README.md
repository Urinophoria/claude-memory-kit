# claude-memory-kit

A **drop-in persistent-memory system for Claude** — git-managed, plaintext, and yours. It gives any
Claude session (Claude Code, Cowork, phone/web) durable, cross-machine memory: what you're working on,
your projects, your context, and how you like to work — so a new session on any machine picks up exactly
where the last one left off.

This is the **mechanics, not anyone's content**: the tooling, the structure, and the discipline that
make a memory system that actually holds. You bring your own notes.

## What you get
- **git-as-transport** — your memory is a private GitHub repo. Every machine clones it; every session
  commits + pushes. No sync client, no daemon, nothing to rot.
- **A `load-memory` skill** — the boot sequence: pull first, read the indexes, deep-read what the task
  needs, tell you what's active.
- **An atoms fast-fact layer** — one-line sourced facts injected into every session so the things you'd
  otherwise re-explain just *surface*. (With a lint that keeps it honest.)
- **A doctor (`dr-check`)** — one command answers "if this machine died, would a fresh one rebuild
  everything?" Green = you're safe.
- **Auto-save hooks** — a safety net that commits + pushes your work at session boundaries, fails
  *loudly* when it can't, and never commits a paused-rebase or an un-redacted secret.
- **A transcript archive** — every session rendered to readable Markdown, secrets redacted.

## Get started
Read **[GETTING-STARTED.md](GETTING-STARTED.md)** — it walks you from "no GitHub account" to a working
memory system: make the account, install the prerequisites, bootstrap the machine, upload the skill,
and add your first context. Then **[STANDARDS.md](STANDARDS.md)** is the short set of rules that keep it
trustworthy, and **[memory/atoms.README.md](memory/atoms.README.md)** explains the atomic structure.

## Requirements (v1)
Windows, with Git for Windows (brings Git Bash — the hooks are bash) and Python 3. The Claude desktop
app or Claude Code. macOS/Linux support is a planned follow-up (the bash tooling already runs there; only
the PowerShell bootstrap is Windows-specific).

## License
MIT — use it, fork it, make it yours.
