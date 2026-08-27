# transcripts/ — the conversation record, in two tiers

Claude Code writes every session verbatim to `~/.claude/projects/<slug>/<id>.jsonl` (outside this repo).
The auto-save hook folds them in here at session boundaries:

- **`raw/`** — full `.jsonl.gz`, every tool result verbatim. **Credential-bearing** (file reads, command
  output). **git-ignored** by design — it never leaves your machine via git.
- **`rendered/`** — the conversation only (what you and Claude *said*), **secrets redacted**, as readable
  Markdown. This tier IS committed + pushed.

`setup/render-session.py` does the rendering + redaction. `setup/recall.py` searches the rendered tier
when you need the exact wording of something that was said. Nothing here needs your attention day-to-day —
the hooks maintain it.
