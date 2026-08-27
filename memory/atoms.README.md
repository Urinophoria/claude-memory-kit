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
and you end up re-feeding a cue you know is already in canon. Atoms are the fix: a compact, always-loaded
layer of one-line facts, each pointing at the `.md` that holds the full story.

Two jobs at once:
1. **Fast-fact store** — the claim surfaces without being asked for.
2. **Router** — the `src` field tells Claude which deep file to open when the topic goes further.

## How it loads
- `memory/atoms.jsonl` — the data (one JSON object per line).
- `setup/atoms-inject.py` / `.sh` — a SessionStart hook that renders your atoms into the session context.
- It reads `utf-8-sig` (tolerates a stray BOM) and warns loudly if a line is corrupt, rather than silently
  dropping a fact.

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
| `status` | no | `open` \| `resolved` \| `superseded`. A `superseded` atom is kept for the trail but NOT injected. |
| `by` | no | id of the atom that superseded this one. |
| `tags` | no | loose topic tags for future filtering. |

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
   paragraph, not an atom.

## Guardrails (mechanical)
- **`py setup/atoms-lint.py`** — the integrity gate. Hard-fails on: a corrupt/BOM line, a missing field, a
  malformed id, a **duplicate id** (rule: ids are permanent, never reuse), an unresolvable `src`, a
  dangling `superseded → by`, or a **dangling cross-reference** (canon text mentions `<prefix>-NN` but no
  such atom exists). Run it before committing atom changes — or just run the doctor, which runs it as a
  hard gate.
- **Numbering:** use the next free number for that prefix (the lint prints the ranges). When two atoms end
  up sharing a number, the one your canon already cross-references by that id keeps it; renumber the other.
- **`setup/atoms-freshness.py`** (advisory) flags a group whose source `.md` was committed well after its
  newest atom — a nudge to re-atomize if that change added facts.

## Getting started with your own atoms
The seed file has a couple of examples — replace them. Pick a prefix per topic area (`wr-` for
working-relationship, `srv-` for servers, whatever fits), keep each claim to one line, point `src` at the
`.md` that holds the detail, and let the lint keep you honest.
