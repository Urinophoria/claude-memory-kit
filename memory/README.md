# memory/ — your global context

One `.md` file per **topic**: a subsystem, a relationship, a decision area, a runbook. These hold the
narrative and the depth. The one-line facts worth surfacing every session get distilled into **atoms**
(`atoms.jsonl`) that point back here.

- **Every file gets frontmatter** (`name:` + `description:`) — `name:` is how `[[wiki-links]]` resolve,
  `description:` shows in the `MEMORY.md` index.
- `SECRETS.local.md` lives here too but is **git-ignored** — real credential values, never committed.
- Start with `example.md` (delete it once you have your own), and `atoms.README.md` for the fast-fact layer.
