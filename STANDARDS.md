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

### 2A. Saving by hand — use `setup/canon-save.sh`, never a hand-rolled git chain
The hooks fail loud; a git chain typed into the Bash tool bypasses all of that. Two classic ways it lies:
- **Wrong order.** `pull --rebase` refuses a dirty tree. The save order is **add → commit → pull --rebase → push**.
- **Pipe-masking.** A pipeline returns its *last* stage's exit code, so `git push … | tail` reports 0 even
  when the push was rejected, and an `&&` chain sails on. Proof: `false | tail; echo $?` prints `0`.

So:
- **Use the script:** `bash setup/canon-save.sh "subject" "" "body…"` — `set -euo pipefail`, correct order,
  authored message required, atoms-lint gated (a hard lint failure refuses the whole save), artifact-verified.
- **Never pipe a git op whose success you depend on.** If you must, `set -o pipefail` first.
- **Verify the artifact after any push, not the exit line:** `git fetch`, then
  `git merge-base --is-ancestor HEAD origin/main`. "It didn't error" is not "it landed."

Why a script for something you do rarely: the saves you do constantly (rote, unfocused) and the ones you do
once a month (unpracticed) are both where hand-entry burns you. Encode the judgment once.

### 2B. Before offering a new session (spawn / fork / branch) — checkpoint this one first
The moment Claude is about to offer a new session, it does **not** offer it yet. First, in order:
1. **Download the transcript** — `bash setup/spawn-checkpoint.sh begin`: archive + render + commit
   `rendered/` + mirror the raw tier off-box (`transcripts/mirror-target.txt`). If this box can't reach its
   mirror, Claude **asks you to connect it** (that's almost always fixable — see §7); only you can waive it
   (`--mirror-waived "your reason"`).
2. **Update memory + every relevant project** (`memory/*.md`, `code/<proj>/PROJECT.md`) with what the new
   session is for, and why.
3. **Create an atom referencing those updates** (its `src` = one of the files from step 2). Save with
   `setup/canon-save.sh`, then `bash setup/spawn-checkpoint.sh verify`.

Then offer it, naming the atom + updated files in the brief.

**Why:** spawned sessions can hand work to each other through git, with no human in the loop — but the
*parent's* reasoning lives only in its live transcript until the session ends. One lost session and the "why"
is gone. The checkpoint puts the parent's context in canon before the child exists, so the child (and every
later session) can read its parent, not just its brief.

**Enforced:** `setup/spawn-guard.sh` (PreToolUse on the app's spawn, start-session and hand-off/fork tools)
blocks until a `verify` **by the same session** in the last 60 min. Stamps are per session, so a parent's
checkpoint never covers a child started in its folder; a failed `begin` leaves no stamp, and `verify` consumes
the `begin` it proved (and refuses to run in a shell with no session id). The step 2-3 evidence is any commit
after the session's own `begin`, not bound to which session made it. `begin` proves THIS session's own rendered
transcript is tracked and committed, by the `| Session |` header inside the file, not its name (a clean
`rendered/` is not proof; two same-day sessions with the same opening prompt used to share one rendered file --
render now suffixes the second with its short id); `verify` checks a commit since `begin`, a narrative file changed, a new atom whose
`src` is one of those files, and everything pushed. A plain-text offer ("want me to spin this off?") can't be
hooked, so the rule binds it anyway. Regression-tested in `setup/test-save-gates.sh` (T30-T37; T30b reads the
matcher itself out of `.claude/settings.json`).

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
- **The same goes for access.** If a task needs reach Claude doesn't have right now (a VPN, a console, an
  on-premises service, an admin prompt), Claude **asks you to provide it** — asking is the move. It never
  quietly narrows the task or skips the part it can't reach.
- **The other edge: a genuinely portable primitive is not a workaround.** The rule targets a *weaker*
  stand-in chosen to dodge a tool that exists and is installable. It does not forbid the *right* portable
  primitive when the usual tool is verifiably absent and not cleanly installable on that platform (e.g.
  `flock` doesn't exist in Git Bash on Windows; an atomic `mkdir` lock is a correct cross-platform lock).
  Either way, Claude says what it chose and why — never silently.

## 8. Two deeper tiers are QUERIED, never loaded
The `.md` files hold *conclusions*. Two other tiers hold the rest, reached on demand:
- **Why** — `bash setup/why.sh <keywords>` reads commit-message bodies: why a change happened, what it
  replaced. Reach for it before overturning a past decision.
- **What was said** — `py setup/recall.py -p <words>` searches your own words in the rendered transcripts.
  Reach for it when you need the nuance a summary dropped. Search the words that were *said*, not the
  summary of them.

## 9. The Windows bootstrap chain must run on a FRESH machine under PowerShell 5.1
`bootstrap.cmd` → `powershell.exe` (**5.1**) → `bootstrap.ps1` → `setup-windows.ps1` is the one path that
can't assume PowerShell 7 or any installed tool — it's what installs them. Its bugs are invisible on a
machine that's already set up, so they only bite on a new machine or a rebuild. The rules:
- **ASCII only in every bootstrap `.ps1`.** 5.1 reads a BOM-less `.ps1` as Windows-1252, so a UTF-8 em dash
  (`E2 80 94`) decodes to three characters, the last a *double quote* that ends the string early — the
  whole file fails to parse. A BOM is a crutch an editor can strip; write `-`, `->`, `...` instead.
  Check both editions: `powershell` *and* `pwsh` (`dr-check [8]` parse-checks every `setup/*.ps1` under 5.1).
- **Under `$ErrorActionPreference = "Stop"`, a native command that writes to stderr throws** in 5.1 —
  with `2>&1` *and* with `2>$null`. Probe native tools (Python's Store stub prints "Python was not found"
  to stderr) inside a local `$ErrorActionPreference = "SilentlyContinue"`, restored in `finally`.
- **A tool winget just installed is not on this process's PATH.** Probe on disk or prepend its folder.
- **Re-runs must be safe** — the failure banner says "re-run": never clobber a backup, never hard-exit
  on an "already installed" state.
- **Silence is the failure.** Gate every "OK" on the exit code or the artifact, and `exit 0` explicitly at
  the end, so a trailing benign non-zero can't brand a good machine "FAILED". Only an end-to-end run on a
  truly fresh machine finds this class.

---
*This is a starter set. Add your own rules as you learn what your workflow needs — that's the point.*
