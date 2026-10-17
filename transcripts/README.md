# transcripts/ — the conversation record, in two tiers

Claude Code writes every session verbatim to `~/.claude/projects/<slug>/<id>.jsonl` (outside this repo).
The auto-save hook folds them in here at session boundaries:

- **`raw/`** — full `.jsonl.gz`, every tool result verbatim. **Credential-bearing** (file reads, command
  output). **git-ignored** by design — it never leaves your machine via git.
- **`rendered/`** — the conversation only (what you and Claude *said*), **secrets redacted**, as readable
  Markdown. This tier IS committed + pushed.

`transcripts/render-session.py` does the rendering + redaction. `setup/recall.py` searches the rendered tier
when you need the exact wording of something that was said. Nothing here needs your attention day-to-day —
the hooks maintain it.

## Off-box copies of the raw tier: `mirror` and selective `drift`
`raw/` is git-ignored, so on its own it lives on one disk. Two optional, per-machine targets copy it off-box
(both files are gitignored; absent file = off; a configured target that fails is reported loudly):

- **`mirror-target.txt`** — one line, a path (a NAS share, another disk). `transcript-autosave` copies
  **every** session there at each session boundary, gzip-CRC-verified.
- **`drift-target.txt`** — a second, **narrower** archive that takes only the sessions
  `drift-policy.txt` clears. For when one archive may hold everything but another may not (say, a work
  machine whose sessions may all go to the work archive, but to a personal NAS only if no sensitive
  record content was put in front of Claude).

```bash
py -3 transcripts/render-session.py classify     # hold / drift / wait for every archived session
py -3 transcripts/render-session.py classify --dir //nas/share/raw   # audit what's already on a target
py -3 transcripts/render-session.py drift        # copy only policy-cleared sessions to drift-target.txt
py -3 transcripts/drift-test.py                  # regression test (temp dir, built-in example policy)
```

- **Policy** = tracked `drift-policy.txt` (your decisions travel with the repo): data `root`s, record-returning
  connector `tool`s, record-system `match` patterns, explicit `hold`/`drift` lines, and `settle` hours. It
  ships with no roots, so until you add some, drift takes every settled session. It judges what a session
  **reached for** (tool inputs): reading a record holds; listing, moving, inventorying a data folder,
  reading a pipeline's own logs/manifests (`workfile`), or writing *about* a folder drifts.
- **Only settled sessions drift** (quiet `settle` hours), so a verdict can't flip after the copy.
- **It never deletes.** A held session already on the target is printed for you to remove.
