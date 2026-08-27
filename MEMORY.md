# MEMORY — top index

> The first thing `load-memory` reads. Keep it a **highlights index + pointers**, not a second copy of
> everything. One-line summaries here; the depth lives in the files they point at.

## ⏩ ACTIVE SESSION HANDOFF — updated YYYY-MM-DD (machine: NAME)
**What we were doing:** _(1–3 sentences, present tense — rewrite this every save)_
**State right now:** _(what's done / running / staged)_
**⚠️ Next action:** _(the single concrete next step, with the command or file path)_
**Blocked on:** _(person / decision / nothing)_

## Global memory files
| File | Summary |
|---|---|
| [memory/example.md](memory/example.md) | Example topic file — delete once you have real ones |
| [memory/atoms.README.md](memory/atoms.README.md) | Format + discipline for the atoms fast-fact layer |
| [STANDARDS.md](STANDARDS.md) | The binding rules that keep the system trustworthy |

_(Add a row per `memory/*.md` as you create them. This is highlights — `load-memory` reads the full
`memory/` directory's index, and deep-reads a file when a task reaches it.)_

## Active code projects
| Project | Status | Last active | Next |
|---|---|---|---|
| _(none yet)_ | | | |

_(One row per `code/<name>/PROJECT.md`. Keep it in sync with `code/INDEX.md` — `dr-check` verifies they
agree.)_
