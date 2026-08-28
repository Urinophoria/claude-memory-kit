# Skill registry — this repo's skills & their per-machine upload state

**Why this file exists.** The skills in `skills/` (e.g. `load-memory`) are NOT served from the git repo.
Each machine **manually uploads a zip** into its Cowork / claude.ai skill registry, and *that uploaded
copy — not the repo — is what actually runs.* So the repo copy can be updated for weeks while a machine
keeps serving a months-old snapshot. This registry tracks which build each machine uploaded, so staleness
is visible. `load-memory`'s **STEP 0 self-check** compares its stamped `SKILL_VERSION` to the canonical
date below and warns if the served copy is behind.

## The rule (STANDARDS §7A)

Editing a `skills/<name>/SKILL.md` is not "done" until it is **re-packaged** and **re-uploaded** on the
machine you edited from, with this registry updated the same session. Re-package with
`pwsh -File setup/package-skills.ps1` — it **refuses to package a clone that is behind origin**, so you
never ship a stale skill even when your process is otherwise correct. Then in Cowork / claude.ai skills,
remove the old skill and upload the fresh `Downloads/cowork-skills/<name>.zip` (upload is per-account /
per-machine — one machine's upload does NOT fix another). Other machines re-upload when their logged date
is older than the canonical date below.

## Canonical versions (source of truth — compare your uploaded copy to these)

| Skill | SKILL.md last changed | Notes |
|---|---|---|
| `load-memory` | **2026-08-27** | Boot sequence: awareness via the indexes + deep-read on demand; STEP 0 served-copy staleness self-check + `SKILL_VERSION` stamp. |

## Upload log (each machine signs its own row — never infer another's)

| Machine | load-memory uploaded | Notes |
|---|---|---|
| _(your machine)_ | ⬜ record the date you upload | one machine's upload does NOT fix another |

> ⬜ = never recorded. A machine whose uploaded copy predates the canonical date above is serving stale
> doctrine — re-package (`package-skills`) + re-upload, then set the date here.
