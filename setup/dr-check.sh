#!/usr/bin/env bash
# dr-check.sh — Disaster-Recovery / index-tree DOCTOR for the Claude-Memory ecosystem.
#
# Answers ONE question: "If your primary machine died right now, would `bootstrap` on a fresh V2 bring
# up EVERY project exactly where we left off?" It verifies the index tree is internally consistent
# (STANDARDS §3 — manifest ↔ clones ↔ PROJECT.md ↔ MEMORY.md ↔ code/INDEX.md all agree) and that
# nothing is stranded locally (uncommitted / unpushed). This is the machine-check behind the
# discipline: run it any time you want to PROVE a V2 rebuild would be lossless.
#
# Run:   bash setup/dr-check.sh            (resolves the repo via $HOME)
# Exit:  0 = green (lossless V2), 1 = gaps found (listed above).

set -u
MEM="${HOME}/Claude-Memory"
PROJ="${MEM}/Projects"
CODE="${MEM}/code"
MANIFEST="${MEM}/setup/project-repos.txt"
FAIL=0
STALE=0
warn()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }
ok()    { echo "  ✓ $1"; }
note()  { echo "  ? $1"; }
# STALE = this machine is BEHIND origin. Distinct from FAIL on purpose: it does NOT threaten a V2
# rebuild (canon already has the commits) — it means the box you are sitting at is reading stale
# truth. Added after two clones were found several commits behind
# while this doctor reported both "clean + pushed".
stale() { echo "  ⤓ $1"; STALE=$((STALE+1)); }
# UNVERIFIED = we could NOT reach origin (fetch failed), so the ahead/behind/lossless verdict is
# computed against STALE local refs and cannot be trusted. Distinct from STALE on purpose: STALE means
# "canon is whole, this box is just behind"; UNVERIFIED means "we don't KNOW canon is whole." A failed
# fetch must NEVER read as a clean bill of health (2026-08-26 pass-2: the stale verdict falsely
# certified 'canon is whole' on a fetch failure).
UNVERIFIED=0
unverified() { echo "  ⚠ $1"; UNVERIFIED=$((UNVERIFIED+1)); }
# ATOMS = the fast-fact layer's integrity lint or its delivery check ([6]) failed. Kept DISTINCT from FAIL on purpose: atoms.jsonl is
# git-tracked and restores byte-identical, so a bad atom does NOT threaten a lossless rebuild — routing it
# through FAIL would wrongly flip the losslessness verdict RED over a cosmetic typo. So atoms lint failure is
# a LOUD ADVISORY that never sets FAIL and never gates the exit code; the commit-time write-path gate
# (session-autosave.sh) is what actually stops a bad atom from reaching other machines.
ATOMS=0

echo "===================================================================="
echo " DR DOCTOR — would a fresh-machine rebuild be seamless?"
echo "===================================================================="

# honors each repo's OWN default branch (read live via `git branch --show-current`, so main/master/… all work)
check_repo_clean_pushed() {
  local dir="$1" label="$2"
  [ -d "$dir/.git" ] || { warn "$label: not cloned / not a git repo"; return; }
  local br; br=$(git -C "$dir" branch --show-current 2>/dev/null)
  # FAIL-LOUD (2026-08-26, T1): capture the fetch result. This doctor's whole premise is proving a
  # V2 rebuild would be lossless — but ahead/behind below are computed from LOCAL remote-tracking
  # refs. If the fetch silently failed (auth/network/renamed remote), those refs are stale and a
  # "clean + pushed + current" verdict is a LIE. So on fetch failure, flag the repo as ⤓ stale
  # (verdict UNVERIFIED) instead of letting it pass as GREEN on refs we never refreshed.
  local fetch_ok=1
  git -C "$dir" fetch -q origin 2>/dev/null || fetch_ok=0
  if [ "$fetch_ok" = "0" ]; then
    unverified "$label: 'git fetch' FAILED — the clean/ahead/behind verdict below is vs STALE local refs (auth/network/renamed remote?); freshness UNVERIFIED, cannot certify lossless until origin is reachable"
  fi
  local unc ahead behind
  unc=$(git -C "$dir" status --porcelain 2>/dev/null | grep -c .)
  ahead=$(git -C "$dir" rev-list --count "origin/${br}..HEAD" 2>/dev/null || echo "?")
  # remote→local direction: commits canon has that this clone does NOT
  behind=$(git -C "$dir" rev-list --count "HEAD..origin/${br}" 2>/dev/null || echo "?")
  # stranded-work status (mutually exclusive — fix uncommitted before unpushed)
  if   [ "$unc" != "0" ]; then warn "$label: $unc uncommitted change(s) — LOST on a V2 clone (commit+push)"
  elif [ "$ahead" != "0" ]; then warn "$label: $ahead commit(s) not pushed to origin/$br — V2 wouldn't get them"
  elif [ "$behind" = "0" ]; then ok "$label: clean + pushed + current (origin/$br)"
  fi
  # BEHIND is evaluated INDEPENDENTLY, never in the elif chain above: a repo can be both dirty and
  # stale, and "dirty" must not mask "stale" — that combination is precisely how you end up
  # committing on top of an old base. (Learned while testing this check, 2026-07-30.)
  if [ "$behind" != "0" ] && [ "$behind" != "?" ]; then
    stale "$label: $behind commit(s) BEHIND origin/$br — nothing stranded, but THIS box is reading stale truth (git pull --rebase)"
  fi
}

echo ""; echo "[1] Memory repo (canon) + secrets + discipline hooks"
check_repo_clean_pushed "$MEM" "Claude-Memory"
[ -f "$MEM/memory/SECRETS.local.md" ] && ok "SECRETS.local.md present (V2 gets it from launcher/OneDrive Personal Vault/offline-zip — NOT git)" || warn "SECRETS.local.md MISSING locally — V2 can't resolve credential placeholders"
if grep -q '"SessionStart"' "$MEM/.claude/settings.json" 2>/dev/null && grep -q '"Stop"' "$MEM/.claude/settings.json" 2>/dev/null; then
  ok "§2 hooks wired (SessionStart pull-check + Stop autosave)"
else warn ".claude/settings.json missing SessionStart/Stop hooks"; fi

echo ""; echo "[2] Index-tree consistency (manifest / clone / PROJECT.md / both index tables)"
manifest_names=$(grep -vE '^\s*#|^\s*$' "$MANIFEST" | sed 's#.*/##; s#\.git$##')
for n in $manifest_names; do
  [ -d "$PROJ/$n/.git" ]        && ok "$n: cloned"                    || warn "$n: in manifest but NOT cloned"
  [ -f "$CODE/$n/PROJECT.md" ]  && ok "$n: has code/$n/PROJECT.md"    || warn "$n: NO code/$n/PROJECT.md (index-tree hole)"
  grep -q "$n" "$MEM/MEMORY.md"  && ok "$n: indexed in MEMORY.md"      || warn "$n: MISSING from MEMORY.md table"
  grep -q "$n" "$CODE/INDEX.md"  && ok "$n: indexed in code/INDEX.md"  || warn "$n: MISSING from code/INDEX.md table"
done
for d in "$PROJ"/*/; do
  [ -d "$d" ] || continue; n=$(basename "$d")
  echo "$manifest_names" | grep -qx "$n" || warn "$n: cloned but NOT in manifest — V2 bootstrap wouldn't clone it"
done
# Repo-less canon projects: a code/<n>/ with a PROJECT.md but NO repo (a design-record project with no repo yet).
# The manifest loop above skips these entirely, so they sat outside every consistency check — verify at
# least that they're indexed in both tables (such projects otherwise sit outside every loop).
for cdir in "$CODE"/*/; do
  [ -d "$cdir" ] || continue; n=$(basename "$cdir")
  [ -f "$cdir/PROJECT.md" ] || continue
  [ -d "$PROJ/$n/.git" ] && continue                      # a real clone → already covered by [2] above
  echo "$manifest_names" | grep -qx "$n" && continue      # in the manifest (clone pending) → covered above
  grep -q "$n" "$MEM/MEMORY.md"  && ok "$n (repo-less): indexed in MEMORY.md"     || warn "$n (repo-less canon project): MISSING from MEMORY.md table"
  grep -q "$n" "$CODE/INDEX.md"  && ok "$n (repo-less): indexed in code/INDEX.md" || warn "$n (repo-less canon project): MISSING from code/INDEX.md table"
done

echo ""; echo "[3] Every project repo clean + pushed (no stranded work)"
for d in "$PROJ"/*/; do [ -d "$d" ] && check_repo_clean_pushed "$d" "$(basename "$d")"; done

echo ""; echo "[4] PROJECT.md freshness vs last SUBSTANTIVE commit (drift heuristic — the dashboard lesson)"
# Compare PROJECT.md against the date of the last commit that changed something OTHER than pure
# housekeeping (.gitignore / README / LICENSE / .gitattributes). Using raw HEAD date instead made a
# fleet-wide housekeeping commit (e.g. the 2026-08-26 .gitignore baseline) flag 8/9 projects as false
# DRIFT — a housekeeping commit is not project movement (pass-2 finding). Empty result (a repo with
# ONLY housekeeping history) falls back to HEAD so a genuinely-new repo still gets checked.
for d in "$PROJ"/*/; do
  [ -d "$d/.git" ] || continue; n=$(basename "$d"); pf="$CODE/$n/PROJECT.md"
  [ -f "$pf" ] || continue
  hd=$(git -C "$d" log -1 --format=%cd --date=short -- \
        ':(exclude).gitignore' ':(exclude)README.md' ':(exclude)README.txt' \
        ':(exclude)LICENSE' ':(exclude).gitattributes' 2>/dev/null)
  [ -n "$hd" ] || hd=$(git -C "$d" log -1 --format=%cd --date=short 2>/dev/null)
  if grep -q "$hd" "$pf"; then ok "$n: PROJECT.md references last-substantive date ($hd)"
  else note "$n: last substantive commit is $hd but PROJECT.md doesn't mention it — CHECK for drift"; fi
done

echo ""; echo "[4b] PROJECT.md single-source — code/ vs repo CONTENT (the 08-14 dual-home fork lesson)"
# WHY: [2]/[4] only check that code/<n>/PROJECT.md EXISTS and mentions the repo HEAD date. Neither
# ever compared code/ content against the project repo's own Projects/<n>/PROJECT.md — so when the
# three 2026-08-14 projects were scaffolded with a PROJECT.md in BOTH homes and only the code/ side
# was maintained, this doctor reported the live forks GREEN for weeks. Added 2026-08-23 after the
# cross-machine investigation (cowork/chimera-fork-investigation-2026-08-23). Durable fix = PROJECT.md
# gets ONE home (canon code/), the pre-08-14 norm; this is the interim detector. CRLF-normalized so
# line-ending checkout noise can't masquerade as a fork. Advisory (?) not FAIL: canon code/ stays the
# authoritative resume copy, so a V2 rebuild is still lossless — but it IS drift worth naming loudly.
for d in "$PROJ"/*/; do
  [ -d "$d/.git" ] || continue; n=$(basename "$d")
  rf="$d/PROJECT.md"; cf="$CODE/$n/PROJECT.md"
  [ -f "$rf" ] || continue                         # repo carries no PROJECT.md → single-source, ideal
  # A declared stub (first line carries the PROJECT.MD-STUB marker) is the sanctioned pointer form
  # of single-source (2026-08-24 durable fix): it holds no content that could fork. Verify it stays
  # a stub — a stub that grew real content is the dual-home coming back.
  if head -1 "$rf" | grep -q "PROJECT.MD-STUB"; then
    if [ "$(wc -l < "$rf")" -le 25 ]; then ok "$n: repo-side PROJECT.md is a declared stub pointer — single-source"
    else note "$n: PROJECT.md stub has GROWN ($(wc -l < "$rf") lines) — content is creeping back into the repo side; move it to canon code/"; fi
    continue
  fi
  if [ ! -f "$cf" ]; then note "$n: repo has a PROJECT.md but canon code/ does NOT — decide the one home"; continue; fi
  if diff -q <(tr -d '\r' < "$cf") <(tr -d '\r' < "$rf") >/dev/null 2>&1; then
    note "$n: dual-home PROJECT.md (identical now) — one edit from a fork; durable fix = ONE home (canon code/)"
  else
    dl=$(diff <(tr -d '\r' < "$cf") <(tr -d '\r' < "$rf") 2>/dev/null | grep -cE '^[<>]')
    note "🔱 FORK: $n — code/ and repo PROJECT.md DISAGREE (~$dl lines). canon code/ is authoritative; repo copy is stale. Reconcile pending (Paul's one-time call); durable fix = PROJECT.md ONE home."
  fi
done

echo ""; echo "[5] Stranded canon — remote branches + worktrees no other check watched (the 08-15 worktree lesson)"
# WHY: every OTHER check measures only origin/main and the MAIN worktree. Claude Code worktree
# sessions commit to claude/* branches; the branch reaches origin but if the session ends without a
# merge it never lands on main — and dr-check would report GREEN while a whole project + a
# long doc sat stranded on such a branch for days —
# so: FAIL on any remote branch carrying commits
# unreachable from the default branch (that IS canon a V2 clone of main would miss), and NOTE any
# extra registered worktree (a stale checkout is a stale-truth trap for recursive tools that ignore
# .git/info/exclude). Refs are already fresh from the fetch in [1] — no extra network needed.
# check one repo's remote branches for commits unreachable from its default branch.
# sevfn = warn (canon: an unmerged branch IS stranded canon) or note (a project repo: an unmerged
# branch is often a legit in-flight feature/PR, so advise rather than FAIL — pass-2 extended [5] to
# project remotes but they must not turn the doctor red on normal feature-branch development).
check_stranded() {
  local dir="$1" label="$2" def="$3" sevfn="$4" any=0 br cnt
  while IFS= read -r br; do
    [ -n "$br" ] || continue
    case "$br" in "origin"|*/HEAD) continue;; esac   # skip the bare origin/HEAD symbolic ref (pass-2 [5] fix)
    cnt=$(git -C "$dir" rev-list --count "origin/${def}..${br}" 2>/dev/null || echo 0)
    if [ "${cnt:-0}" -gt 0 ] 2>/dev/null; then
      "$sevfn" "STRANDED: ${label}:${br} has ${cnt} commit(s) NOT on origin/${def} — a V2 clone of the default branch would MISS them. Merge or delete the branch (in-flight PR? confirm with 'gh pr list')."
      any=1
    fi
  done <<INNER
$(git -C "$dir" for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null | grep -v "^origin/${def}\$")
INNER
  [ "$any" -eq 0 ] && ok "${label}: no stranded remote branches (all reachable from origin/${def})"
}
check_stranded "$MEM" "Claude-Memory" "main" warn
# extend to every project remote — a stranded claude/* worktree branch can hide there too (pass-2)
for pd in "$PROJ"/*/; do
  [ -d "$pd/.git" ] || continue; pn=$(basename "$pd")
  pdef=$(git -C "$pd" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
  [ -n "$pdef" ] || pdef=$(git -C "$pd" branch --show-current 2>/dev/null)
  [ -n "$pdef" ] || pdef=main
  check_stranded "$pd" "$pn" "$pdef" note
done
wt_total=$(git -C "$MEM" worktree list 2>/dev/null | grep -c .)
if [ "${wt_total:-1}" -gt 1 ]; then
  while IFS= read -r line; do
    wpath=${line%% *}
    note "extra git worktree registered: ${wpath} — a stale checkout is a stale-truth trap (recursive tools may read it as canon); 'git worktree remove' it once its branch is merged (08-24 sweep)"
  done <<EOF
$(git -C "$MEM" worktree list 2>/dev/null | tail -n +2)
EOF
fi

echo ""; echo "[6] Scale & freshness gates (advisory growth alarms — not V2 blockers)"
# WHY: single-Read-mandated files silently truncate past ~57 KB (~24k tok at the measured 2.39 B/tok),
# and the tail goes invisible — exactly how the open-items health hard-gate hid (2026-08-24 sweep).
# These are notes (?), never FAIL — they buy lead time to trim/split before something breaks. (The atoms
# DELIVERY check below is louder: it reports on the ATOMS advisory channel.)
for pair in "open-items.md:57000" "STANDARDS.md:57000"; do
  fn="memory/${pair%%:*}"; lim="${pair##*:}"
  b=$(wc -c < "$MEM/$fn" 2>/dev/null || echo 0)
  [ "${b:-0}" -gt "$lim" ] && note "$fn is $b B (~$((b*10/24)) tok) — near/over the ~57 KB single-Read cap; trim or split (archive resolved, pin gates — T3 pattern)"
done
b=$(wc -c < "$MEM/MEMORY.md" 2>/dev/null || echo 0)
[ "${b:-0}" -gt 90000 ] && note "MEMORY.md is $b B (~$((b*10/24)) tok) — the top index needs 2+ Reads; keep the table to highlights, roster is every memory/*.md"
# atoms DELIVERY. Claude Code caps a hook's additionalContext at 10,000 chars; past it the model gets a file
# path + a 2 KB preview. Measuring the JSON envelope against a loose byte budget (this check's old form) can
# bless a layer that never loads. So: measure the FIELD the model gets, and probe the newest real transcript
# for the persisted-output marker. Loud advisories on the ATOMS channel (atoms problems never flip the
# lossless verdict). The probe prints a boolean + a length, never content.
apy6=""; for c in py python3 python; do command -v "$c" >/dev/null 2>&1 && { "$c" -c 'print(1)' 2>/dev/null | grep -q 1 && apy6="$c" && break; }; done
if [ -n "$apy6" ]; then
  bl=$(bash "$MEM/setup/atoms-inject.sh" </dev/null 2>/dev/null | "$apy6" -c "import json,sys
try: print(len(json.load(sys.stdin)['hookSpecificOutput']['additionalContext']))
except Exception: print(-1)")
  if [ "${bl:--1}" -lt 0 ]; then
    if grep -q '"id"' "$MEM/memory/atoms.jsonl" 2>/dev/null; then
      echo "  ⚠ atoms boot tier rendered NOTHING parseable — the SessionStart layer is silent. Run: $apy6 setup/atoms-inject.py --stats"; ATOMS=$((ATOMS+1))
    else
      note "atoms boot tier is empty — memory/atoms.jsonl has no atoms yet (fine on a fresh install)"
    fi
  elif [ "$bl" -gt 10000 ]; then
    echo "  ⚠ atoms boot tier is $bl chars — OVER Claude Code's 10,000-char hook cap: sessions get a 2 KB preview, not the tier. Trim 'boot' tags (atoms-lint)"; ATOMS=$((ATOMS+1))
  else
    ok "atoms boot tier is $bl chars (cap 10,000) — delivered whole"
  fi
  probe=$("$apy6" - <<'PROBE' 2>/dev/null
import glob, json, os, re
# newest by session START, not mtime: the session running dr-check is always the most recently WRITTEN
# file, and it may have booted on an older injector than the session that started after it
def started(f):
    try:
        for i, line in enumerate(open(f, encoding="utf-8", errors="replace")):
            m = re.search(r'"timestamp":\s*"([^"]+)"', line)
            if m or i > 40:
                return m.group(1) if m else ""
    except Exception:
        pass
    return ""
fs = sorted(glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")), key=os.path.getmtime, reverse=True)[:12]
fs.sort(key=started, reverse=True)
for f in fs:
    try:
        for line in open(f, encoding="utf-8", errors="replace"):
            if '"hook_additional_context"' not in line or "CANON ATOMS" not in line:
                continue
            for c in json.loads(line)["attachment"]["content"]:
                if "CANON ATOMS" in c or "additionalContext" in c and "persisted-output" in c:
                    print("persisted" if "persisted-output" in c else "inline", len(c)); raise SystemExit
    except SystemExit:
        raise
    except Exception:
        continue
print("none")
PROBE
)
  case "$probe" in
    persisted*) echo "  ⚠ newest session's atoms boot was PERSISTED to a file (model saw a 2 KB preview) — ${probe#persisted } chars of stub. A session that booted on an older injector shows this until a fresh one starts; if it persists after that, the tier is over the cap"; ATOMS=$((ATOMS+1)) ;;
    inline*)    ok "newest session's atoms boot arrived INLINE (${probe#inline } chars)" ;;
    *)          note "atoms delivery probe: no local transcript with a CANON ATOMS boot (fresh box?) — skipped" ;;
  esac
else
  note "atoms delivery check skipped — no working python interpreter"
fi
# atoms freshness (source .md newer than its group's newest atom, 2-day grace)
apy=""; for c in py python3 python; do command -v "$c" >/dev/null 2>&1 && { "$c" --version >/dev/null 2>&1 && apy="$c" && break; }; done
[ -n "$apy" ] && "$apy" "$MEM/setup/atoms-freshness.py" 2>/dev/null
# canon-authored skills are served from a PER-MACHINE upload, not the repo — a machine can serve a
# months-stale copy while the repo is current (2026-08-24 sweep critical). Surface the repo dates so
# a machine whose skill-registry.md row predates them knows to re-upload. (See setup/skill-registry.md.)
for sk in "$MEM"/skills/*/SKILL.md; do
  [ -f "$sk" ] || continue; sn=$(basename "$(dirname "$sk")")
  sd=$(git -C "$MEM" log -1 --format=%cs -- "skills/$sn/SKILL.md" 2>/dev/null)
  [ -n "$sd" ] && note "skill '$sn' repo SKILL.md is $sd — RE-UPLOAD on any machine whose skill-registry.md upload-log row is older (served copy != repo; the June load-memory is dangerous)"
done

echo ""; echo "[7] Atoms integrity (ADVISORY tier — duplicates / dangling refs / malformed break the fast-fact layer; the save paths gate it)"
# Enforces the atoms.README 'never reuse an id' rule + catches a dangling cross-reference (canon points
# at an atom that doesn't exist) and any corruption that would silently degrade the SessionStart layer.
if [ -n "${apy:-}" ]; then
  if ! "$apy" "$MEM/setup/atoms-lint.py"; then
    echo "  ⚠ atoms.jsonl FAILED integrity lint (detail above) — FIX memory/atoms.jsonl. ADVISORY ONLY: this does"
    echo "    NOT threaten a lossless rebuild (atoms.jsonl is git-tracked, restores byte-identical); it does not"
    echo "    flip the verdict below. The session-autosave write-path gate already holds a bad atom back."
    ATOMS=$((ATOMS+1))
  fi
else
  note "atoms lint skipped — no working python interpreter"
fi

echo ""
echo "===================================================================="
if [ "$FAIL" -gt 0 ]; then
  echo " ⚠️  $FAIL gap(s) above would break a seamless V2. Close them before trusting DR."
  [ "$UNVERIFIED" -gt 0 ] && echo " ⚠ ALSO: $UNVERIFIED repo(s) could not reach origin — freshness UNVERIFIED (see ⚠ above)."
  [ "$STALE" -gt 0 ] && echo " ⤓ ALSO: $STALE repo(s) are behind origin — pull before acting on what you read."
elif [ "$UNVERIFIED" -gt 0 ]; then
  echo " ⚠ UNVERIFIED — could NOT reach origin for $UNVERIFIED repo(s) (auth / network / renamed remote)."
  echo "    Ahead/behind/lossless were computed against refs we never refreshed, so this is NOT a clean"
  echo "    bill of health — canon may be whole or may not; we cannot tell. Restore connectivity to"
  echo "    origin and re-run before trusting a rebuild."
  [ "$STALE" -gt 0 ] && echo " ⤓ ALSO: $STALE repo(s) already known behind origin."
elif [ "$STALE" -gt 0 ]; then
  echo " ⤓ STALE — canon is whole and a V2 rebuild would still be lossless, BUT $STALE repo(s)"
  echo "    on THIS machine are behind origin. Nothing is stranded; you are reading old truth."
  echo "    Fix: git pull --rebase in each repo marked ⤓ above, then re-run."
else
  echo " ✅ GREEN — a V2 rebuild would be lossless. Every project resumes from canon."
fi
[ "$ATOMS" -gt 0 ] && echo " ⚠ ATOMS: the atoms layer is FAILING (integrity lint or delivery, detail above) — advisory, SEPARATE
    from losslessness above (atoms.jsonl is tracked → a rebuild still restores it byte-identical). Fix
    memory/atoms.jsonl (or trim the boot tier); the commit-time gate already holds a bad atom back. This
    does not change the GREEN/FAIL verdict or the exit code."
echo " (? lines are advisory drift-heuristics, not hard failures — eyeball them."
echo "  ⚠️ a ⤓ stale repo can FAKE a ? drift line: PROJECT.md looks ahead of a HEAD you"
echo "  simply haven't pulled yet. Clear ⤓ first, then judge ?.)"
echo "===================================================================="
[ "$FAIL" -eq 0 ] && [ "$STALE" -eq 0 ] && [ "$UNVERIFIED" -eq 0 ]
