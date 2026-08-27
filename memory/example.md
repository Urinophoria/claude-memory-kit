---
name: example
description: An example memory file — delete this and write your own. Shows the shape a topic file takes.
metadata:
  type: reference
---

# Example topic file

This is what a `memory/*.md` file looks like. Each one is **one topic** — a subsystem, a relationship, a
decision area, a runbook. It holds the *narrative and the depth*; the one-line facts that should surface
every session get distilled into **atoms** (`atoms.jsonl`) that point back here via their `src` field.

**Frontmatter matters:** the `name:` is how `[[wiki-links]]` resolve to this file, and `description:` is
what shows in the `MEMORY.md` index. Keep both accurate.

## How to use this
- Delete this file once you have real ones.
- Name files by topic: `infrastructure.md`, `working-style.md`, `billing-decisions.md`, etc.
- When a fact in here is something you'd want Claude to *know without being asked*, add an atom for it in
  `atoms.jsonl` with `src: example` (or whatever you rename this to).

## Example content
- Decision: we chose Postgres over MySQL for the main DB (2026-01-10) — reasons live here so no one
  re-litigates it.
- Standing rule: never run migrations against prod without a backup first.
- The seed atoms in `atoms.jsonl` point at this file — open it and you'll see how the fast-fact layer and
  the deep layer connect.
