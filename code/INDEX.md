# Code projects index

One row per code project. Each project's `PROJECT.md` has everything needed to resume it on any machine.
This table, the `MEMORY.md` table, and each `PROJECT.md` **must agree** (STANDARDS §3) — `dr-check.sh`
verifies it.

| Project | Status | Last active | Next |
|---|---|---|---|
| _(none yet — copy PROJECT.template.md into code/<name>/PROJECT.md when you start one)_ | | | |

## Adding a project
1. `git init` a repo under `Projects/<name>/` + create its private GitHub repo + push.
2. Add its clone URL to `setup/project-repos.txt`.
3. Copy `code/PROJECT.template.md` to `code/<name>/PROJECT.md` and fill it in.
4. Add a row here and in `MEMORY.md`. Run `dr-check.sh` — it must be GREEN.
