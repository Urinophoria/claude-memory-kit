# Getting started — from zero to a working memory system

This walks you the whole way: make a GitHub account, install the few dependencies, create your own
memory repo from this template, provision your machine, and add your first context. Budget ~30 minutes.
No prior git experience needed — Claude drives git for you day-to-day; you just do this setup once.

---

## The idea, in one paragraph
Your "memory" is a **private GitHub repository** full of plain-text files. Claude reads it at the start of
every session and writes changes back at the end. Because it's on GitHub, **any machine** you own can
clone it and any Claude session can pick up where the last left off. Nothing important lives only on one
computer or only in a chat you can't get back to.

---

## Step 1 — GitHub account + your own copy of the template

1. **Make a GitHub account** (skip if you have one): go to <https://github.com>, click **Sign up**,
   follow the prompts (email, username, password, verify). The free tier is all you need.
2. **Create YOUR memory repo from this template.** On the `claude-memory-kit` repo page, click the green
   **"Use this template" → "Create a new repository"** button. Name it something like `my-memory`, set it
   to **Private**, and create it. GitHub gives you your own copy of all these files under your account.
3. **Copy your repo's clone URL** — the green **Code** button on your new repo → **HTTPS** →
   `https://github.com/<you>/my-memory.git`. You'll need it in Step 3.

> Why a *template* and not a fork: a template gives you a clean, independent repo with no link back here —
> it's yours to fill with your own content.

## Step 2 — Install the dependencies

Install these three (all free):

1. **Git for Windows** — <https://git-scm.com/download/win>. Take the defaults. This also installs
   **Git Bash**, which the memory system's hooks run in. During install it sets up **Git Credential
   Manager**, which pops a browser sign-in the first time you clone a private repo — that's how your
   machine proves it's you.
2. **Python 3** — <https://www.python.org/downloads/> (or the bootstrap will install it via winget).
   Check **"Add python.exe to PATH"** in the installer.
3. **Claude** — the desktop app or Claude Code (<https://claude.ai/download>). Sign in.

## Step 3 — Clone your repo to the right place

Open **PowerShell** and run (paste YOUR URL from Step 1):

```powershell
git clone https://github.com/<you>/my-memory.git "$env:USERPROFILE\Claude-Memory"
```

The first clone opens a browser to sign in to GitHub — do it once, it's cached after.

> **The folder name matters:** clone it to `%USERPROFILE%\Claude-Memory` exactly. The hooks reference that
> path. (You can use a different name, but then edit the paths in `.claude/settings.json`.)

## Step 4 — Provision the machine (bootstrap)

```powershell
cd "$env:USERPROFILE\Claude-Memory"
Copy-Item setup\config.example.ps1 setup\config.ps1     # optional: set your repo URL + git identity in it
.\setup\bootstrap.cmd
```

Bootstrap installs any missing prerequisites, sets up the `~/.claude/CLAUDE.md` pointer, and **packages
the skills into `Downloads\cowork-skills\`**. If anything fails it says **"Bootstrap FAILED"** and stops —
it will never tell you it succeeded when it didn't.

## Step 5 — Add the skill to Claude

Skills don't travel by git — you upload them once per machine through the app:

1. In Claude → **Customize → Skills → `+` (top-right) → Create skill → Upload a skill**.
2. Upload **`load-memory.zip`** from `%USERPROFILE%\Downloads\cowork-skills\`.
   *(Only zips built by `setup\package-skills.ps1` work — they use the entry format the uploader needs.)*

## Step 6 — Your secrets lane (do this once, keep it off git)

Real passwords/keys **never** go in the repo. Tracked files use placeholders like `<DB_PASSWORD>`; the
real values live only in a file called `memory\SECRETS.local.md`, which is git-ignored. Create it by hand
and keep the master copy somewhere safe you control — an encrypted vault, a password manager, or a USB —
and copy it onto each new machine yourself. Example shape:

```
# SECRETS.local.md  (git-ignored — never commit real values)
DB_PASSWORD: your-real-value-here
```

Then in any tracked note you can write `<DB_PASSWORD>` and Claude resolves it from this file at runtime.

## Step 7 — First boot + your first context

In Claude Code, open the `Claude-Memory` folder and say **`/load-memory`**. It reads your (currently
mostly empty) canon and confirms it's ready. Now just talk to it like you would about your work — tell it
what you're working on, decisions you've made, things you don't want to re-explain. At the end of the
session say **"save memory"** (or let the auto-save hook do it), and it writes that back to canon and
pushes it to GitHub. Next session, anywhere, it's there.

---

## How it's organized — the atomic structure

Your memory has a few layers, smallest-and-fastest first:

| Layer | What it is | When it loads |
|---|---|---|
| **atoms** (`memory/atoms.jsonl`) | one-line **sourced facts** ("the staging server is `deploy-2`, not `deploy-1`") | automatically: `boot`-tagged atoms at session start, the rest recalled per message by topic (a small store loads whole) |
| **memory files** (`memory/*.md`) | the narrative + decisions + runbooks behind those facts | read on demand (the atom's `src` points here) |
| **project context** (`code/<proj>/PROJECT.md`) | everything needed to resume a code project | read when you work that project |
| **session notes** (`cowork/<topic>/SESSION.md`) | non-code work threads | read when you resume that thread |
| **reasoning tier** (`git log` bodies, via `setup/why.sh`) | WHY a thing changed / what it replaced | queried when a decision surprises you |
| **transcript tier** (`transcripts/`, via `setup/recall.py`) | what was actually *said*, verbatim | queried when you need the exact wording |

An **atom** is the fast-fact at the top of that stack. It's a tiny JSON line:

```json
{"id":"srv-01","claim":"Prod deploys go through deploy-2 (deploy-1 is decommissioned)","src":"infrastructure","date":"2026-01-15","conf":"high","tags":["ops"]}
```

The **`.md` file named in `src` is the source of truth**; the atom is a distilled pointer to it that
*surfaces* the fact without you asking. While your store is small, every atom loads at session start.
Once it outgrows the hook's 10,000-char cap, only atoms you tag **`boot`** load up front (keep that to
the handful every session needs, whatever the topic); the rest arrive as each message touches their
topic, or on request (`py -3 setuptoms-inject.py --grep TERM`). Full rules:
**[memory/atoms.README.md](memory/atoms.README.md)**.
Run `py setup\atoms-lint.py` any time to check your atoms are well-formed (no duplicate ids, every `src`
resolves) — or just run the doctor, which checks it for you.

## Day-to-day
- **Start a session:** open the folder, say `/load-memory` (it pulls first, so you're never stale).
- **"Is everything saved?"** say **"run the doctor"** → `dr-check.sh`. **GREEN** means a fresh machine
  could rebuild everything perfectly. You're safe.
- **Add a machine:** repeat Steps 2–5 on it. Same repo, same context, everywhere.

That's the whole system. The rules that keep it trustworthy are short — read **[STANDARDS.md](STANDARDS.md)**
next.
