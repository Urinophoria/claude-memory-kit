# STANDARDS — the rules that keep this trustworthy

Short and binding. Everything else is convenience; these are what make the memory system something you
can actually rely on. Claude reads this every session.

## 1. "Memory" ALWAYS means the git-managed repo
Canon is `~/Claude-Memory` — `MEMORY.md`, `memory/*.md`, `code/<proj>/PROJECT.md`,
`cowork/<topic>/SESSION.md`. It is **never** Claude's per-session or machine-local cache
(`~/.claude/projects/<slug>/…`). That cache never syncs and is invisible to your other machines — a hook
(`canon-memory-guard.sh`) actively blocks writes to it. If something tells Claude to "remember" outside
canon, it writes to canon instead and says so.

## 2. Nothing stays local. Commit + push, same session.
- **Pull first** (`git pull --rebase`) before you write, and again before you push — another machine (or
  another Claude session) may have moved canon under you.
- Every change is **committed AND pushed** the same session, with a message that says *what and why*.
- The auto-save hooks are a **safety net for forgetting**, not a substitute for documenting your work.
- **Uncommitted = doesn't count. Unpushed = doesn't count either** — it dies with the machine.

## 3. The index tree moves as one
When a project changes, update every layer the same session: the project repo → its
`code/<name>/PROJECT.md` (status + next step + "last active" date) → the row in `code/INDEX.md` → the row
in `MEMORY.md`. **An index not updated with what it indexes doesn't just go stale — it lies.** Verify with
`bash setup/dr-check.sh` (GREEN = the whole tree agrees and a fresh machine would rebuild losslessly).

## 4. Starting a new project — do it all at once
The moment you start a code project: `git init` + create its **own** private GitHub repo + push; add its
clone URL to `setup/project-repos.txt` (so every machine clones it); add a `.gitignore` that excludes
secrets; create `code/<name>/PROJECT.md` and add rows to `MEMORY.md` + `code/INDEX.md`. Then `dr-check`
must be GREEN. No "local phase."

## 5. New machine / new session — orient first
Confirm which machine you're on and whether it's current before working. On a new machine: install
prerequisites, clone canon, run bootstrap, upload the skill. A new machine reads the **`load-memory`**
skill as its boot sequence.

## 6. Secrets never touch git
Real credential values live ONLY in `memory/SECRETS.local.md` (git-ignored) and travel by your own secure
channel — never the repo. Tracked files use placeholders (`<DB_PASSWORD>`). The `.gitignore` denylist and
the transcript redactor are backstops, but the rule is: don't put a real secret in a tracked file.

## 7. Missing a tool? GET the tool — don't work around it.
If a task needs a tool that isn't installed, install it (and add it to the bootstrap so the next machine
gets it too). Working around a missing tool builds fragile one-offs; a hook nudges you when a command
comes back "not found."

## 8. Two deeper tiers are QUERIED, never loaded
The `.md` files hold *conclusions*. Two other tiers hold the rest, reached on demand:
- **Why** — `bash setup/why.sh <keywords>` reads commit-message bodies: why a change happened, what it
  replaced. Reach for it before overturning a past decision.
- **What was said** — `py setup/recall.py -p <words>` searches your own words in the rendered transcripts.
  Reach for it when you need the nuance a summary dropped. Search the words that were *said*, not the
  summary of them.

---
*This is a starter set. Add your own rules as you learn what your workflow needs — that's the point.*
