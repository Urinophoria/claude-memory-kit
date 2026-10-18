---
name: atoms-readme
description: Format + discipline for the atoms fast-fact layer (memory/atoms.jsonl).
metadata:
  type: reference
---

# Atoms — the fast-fact / retrieval layer

## The problem it solves
Your `memory/*.md` files hold the depth, but they're not all loaded at session start — so discrete facts
you already wrote down ("the staging box is `deploy-2`", "the cert expires in December") don't *surface*,
and you end up re-feeding a cue you know is already in canon. Atoms are the fix: a compact layer of
one-line facts that **surface on their own** (a curated core at session start, the rest recalled when a
message uses their topic words or `cues`), each pointing at the `.md` that holds the full story.

Two jobs at once:
1. **Fast-fact store** — the claim surfaces without being asked for.
2. **Router** — the `src` field tells Claude which deep file to open when the topic goes further.

## How it loads — three tiers
- `memory/atoms.jsonl` — the data (one JSON object per line).
- `setup/atoms-inject.py` — the renderer (pure stdlib). `setup/atoms-inject.sh` — the hook wrapper: picks a
  **working** interpreter (`py` → `python3` → `python`, verifying each actually runs — on Windows the
  `python` on PATH can be a Store stub), passes its arguments through, and always exits 0, so a hook can
  never block a session or a prompt. Both hooks are wired in `.claude/settings.json`.

**Why tiers:** Claude Code caps each hook's `additionalContext` at **10,000 chars** (no setting raises it).
Past that it writes the text to a file and gives the model a path + a 2,000-char preview it is not told to
read. An injector that emits every atom in one blob crosses that line after a few dozen short atoms (or ~10
paragraph-sized ones) — and from then on the "always-loaded" layer silently never loads. Nothing pushes
back, because no session ever sees the rendered result. So the layer is delivered in tiers:

1. **BOOT** — `atoms-inject.sh --hook` (SessionStart). Hard-capped at 9,500 chars: a truthful header ("N of
   M shown, the rest are NOT in context, here is how to get them"), every atom tagged **`boot`** in full,
   the 6 newest others as 140-char gists, and an index line of every `src` with its atom count.
   **Small store:** while *every* active atom fits the budget in full, boot simply shows them all — the
   tiers take over the day the store outgrows it.
2. **RECALL** — `atoms-inject.sh --prompt` (UserPromptSubmit). Scores each of your messages against every
   atom — BM25 over claim + tags + src + id, no embeddings, no network — and injects the best matches this
   session hasn't seen, ≤5,000 chars, ≤5 atoms. A match must share ≥2 words with the atom (≥3 for a long
   paste), one of them a rare **topic** word (from the atom's headline, tags or src), and clear a score
   floor. Naming an id (`srv-01`) recalls it outright. Silent when nothing matches ("go for it", chatter).
   Per-session shown-list in `<temp>/claude-atoms-shown/<session_id>.txt`: reset on startup/clear/compact,
   kept on resume, pruned after 7 days. The rarity anchor needs a store of roughly 20+ atoms before any
   word is rare enough to fire — below that, the small-store boot already shows everything.
3. **LOOKUP** — `py -3 setup/atoms-inject.py --id A,B | --grep TERM | --src NAME [--page N]` (`python3` off
   Windows), plain text, ~20K per page. For the full text behind a `…[gist]`, or a deliberate check.

`--stats` prints sizes as JSON. Bare `atoms-inject.py` (no args) prints the boot payload without touching
stdin or the shown-list — what dr-check measures. The renderer reads `utf-8-sig` (tolerates a stray BOM),
warns loudly in the boot payload if a line is corrupt rather than silently dropping a fact, and renders
every claim as a single line.

**The `boot` tag** is the curated core: facts every session needs whatever the topic, that recall would not
reliably surface — collaboration rules, a standing safety rule, the one address everyone gets wrong.
`atoms-lint` holds the boot claims to **5,000 chars total** (hard) and warns on any boot claim over 700.
Never boot-tag a per-incident atom — the newest-gists slot and recall already cover fresh facts. To change
the core, retag and re-run `--stats`.

**Tuning recall.** The knobs are the constants in `atoms-inject.py` (`MIN_SCORE`, `ANCHOR_IDF`, …), tuned on
a ~350-atom store against 445 real prompts (fires on ~37% of messages, ~3 atoms each). The biggest lever
for your own install is the stopword list: your everyday conversational words are recall noise, and they
differ per person. The comment under `_STOP` explains how to derive yours from your own transcripts. Once
your store is in the hundreds, replay a few hundred of your real prompts through `recall()` and adjust.

**Testing delivery end to end:** `bash setup/dr-check.sh` ([6] checks the boot size against the cap and
whether the newest-started session got it inline), or a real headless session from `~/Claude-Memory`:
`claude -p "Is a CANON ATOMS boot block in your context? Quote its first line." --model haiku --max-turns 1`.
⚠ **A headless session inside `~/Claude-Memory` fires the project's Stop hook**, so `session-autosave`
commits AND pushes the working tree as it stands — half-done work included. Run one only on a tree you
would save.

The atoms layer is the always-on counterpart to the `load-memory` skill's deep read: boot covers the quick
sessions that never invoke the skill, and recall brings in topic facts as the talk turns to them.
**What recall does NOT reach:** standing behavioral rules. Their topic words are labels ('PAUSE FOR
ACCURACY', '#1 HARD RULE') that a message in the moment never uses, so BM25 almost never surfaces them.
Read them through load-memory or `--src NAME`, or give the atom `cues` (below).

## Atom schema
```json
{"id":"srv-01","claim":"Prod deploys go through deploy-2 (deploy-1 is decommissioned)","src":"infrastructure","date":"2026-01-15","conf":"high","status":"open","tags":["ops"]}
```

| field | required | meaning |
|---|---|---|
| `id` | yes | stable handle, `<prefix>-NN` (e.g. `srv-01`, `wr-03`). **Permanent — never reuse a number.** |
| `claim` | yes | ONE self-contained fact, readable with zero other context. Use single quotes inside, not double. |
| `src` | yes | basename (no `.md`) of the source-of-truth file — `memory/<src>.md` or `code/<src>/PROJECT.md`. |
| `date` | yes | when the fact was established / last confirmed (`YYYY-MM-DD`). |
| `conf` | yes | `high` \| `med` \| `low`. Renders as no marker / `~` / `?`. |
| `status` | no | `open` \| `resolved` \| `superseded`. A `superseded` atom is kept for the trail but NOT injected or recalled (`--id` still shows it, flagged). |
| `by` | no | id of the atom that superseded this one. |
| `tags` | no | array of topic tags. They count double in recall scoring and anchor a match, so name the topic (`database`, `deploy`), not a mood. `boot` puts the atom in the boot tier. |
| `cues` | no | array of situation phrases (max 30; each must normalize to >= 6 chars with a real word). A cue appearing in a message recalls the atom OUTRIGHT, bypassing scoring -- for rules whose topic words nobody types in the moment (a 'never work around a missing tool' rule: `not installed`, `no workaround`, `get the tool`, `pip install`). Matching is whole-word and forgiving: case, apostrophes (`isn't` = `isnt` = `isn’t`), hyphen vs space and whitespace runs are normalized, and the last word may take `s/es/d/ed/ged/ing`. Cue the SITUATION, not a topic word (`not in winget`, not `winget`) -- a cue bypasses scoring, so a broad one injects the atom on every mention. Cues on a `boot` atom never fire (it is already shown; lint warns), and while a small store is shown in full at boot no cue fires at all -- cues start to matter once the store outgrows that. Example: `ex-04`. |

## The rules (this is what keeps it honest)
1. **The `.md` file is the source of truth; the atom is a distilled pointer, never a second copy.** If they
   disagree, the file wins — fix the atom.
2. **Update the atom in the same session as the file it points at.** An atom that drifts from its source is
   worse than no atom.
3. **Never delete a reversed fact — supersede it.** Set `status: superseded`, add `by`, write the
   replacement as a new atom. Facts reverse; the trail matters.
4. **Atomize durable, surface-worthy facts** — identities, decisions, standing rules, "don't re-derive
   this" conclusions. NOT blow-by-blow narrative (that stays in the `.md`), and NEVER secrets.
5. **Keep claims short and standalone.** If it needs a paragraph, it's a pointer to the file that holds the
   paragraph, not an atom. **Lead with a topic headline** (`PROD MIGRATIONS: …`) — recall anchors on the
   headline, and a recalled claim over 1,400 chars arrives as a 900-char gist. Claims drift long when no
   one sees the rendered layer; the boot budget and recall gists are what push back.

## Guardrails (mechanical)
- **`py setup/atoms-lint.py`** — the integrity gate. Hard-fails on: a corrupt/BOM line, a missing field, a
  malformed id, a **duplicate id** (rule: ids are permanent, never reuse), an unresolvable `src`, a
  dangling `superseded → by`, or a **dangling cross-reference** (canon text mentions `<prefix>-NN` but no
  such atom exists), or a **boot tier over budget** (`boot` claims > 5,000 chars, or a superseded atom
  tagged `boot`). Both save paths below run it for you; the doctor also runs it, as its own advisory tier
  ([7]; atoms problems never flip the rebuild verdict). A hard failure can come from a `.md` alone: a new
  dangling ref, or deleting/renaming an atom's `src` file.
- **Save-path gate #1 — `setup/session-autosave.sh` (Stop hook).** Lints the **staged index** (a mirror under
  `.git/atoms-lint-snap/`, not the working tree) whenever anything is staged. On a hard failure it **holds
  back** just the implicated staged files (`atoms.jsonl` for a bad atom, each `.md` carrying a dangling ref, a
  staged delete of a `src` file), re-lints, repeats, then commits + pushes the rest. Held files stay dirty and
  uncommitted, so no pusher can carry them. If the tip still fails from a cause already in HEAD: pushed anyway
  when origin already has it, **PUSH WITHHELD** when HEAD has local-only commits (transcript-autosave honors
  that). Every case drops `.git/atoms-lint-FAILED`, which `check-canon` announces at the next SessionStart.
  No python → proceeds unlinted.
- **Save-path gate #2 — `setup/canon-save.sh` (foreground).** Lints before staging whenever there is anything
  to commit or push; a hard failure **refuses the whole save** — the person at the keyboard fixes it.
- **Regression test — `bash setup/test-save-gates.sh`.** Proves both gates (and the STANDARDS 2B spawn
  checkpoint) end to end in a throwaway scratch clone + local bare origin — never your real one — on its own
  synthetic fixture: 91 checks, ~2 min on Windows. **Re-run it after ANY change to a save path.**
- **`dr-check.sh [6]` delivery check** — measures the boot `additionalContext` field (not the JSON
  envelope) against the 10,000 cap, and probes the newest-started local transcript: if that session's
  atoms boot arrived as `<persisted-output>` (the 2 KB-preview fallback), it says so.
- **Numbering:** use the next free number for that prefix (the lint prints the ranges). When two atoms end
  up sharing a number, the one your canon already cross-references by that id keeps it; renumber the other.
- **`setup/atoms-freshness.py`** (advisory) flags a group whose source `.md` was committed well after its
  newest atom — a nudge to re-atomize if that change added facts.

## Getting started with your own atoms
The seed file has a few examples — replace them. Two of them carry the `boot` tag to show the shape of
the curated core. Pick a prefix per topic area (`wr-` for working-relationship, `srv-` for servers,
whatever fits), keep each claim to one line that leads with its topic, point `src` at the `.md` that
holds the detail, tag the topic words, and let the lint keep you honest. Tag `boot` sparingly.
