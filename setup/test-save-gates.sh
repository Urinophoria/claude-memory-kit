#!/usr/bin/env bash
# test-save-gates.sh — end-to-end regression test for the canon SAVE GATES (session-autosave's atoms-lint
# gate, canon-save's refusal, transcript-autosave's PUSH WITHHELD honor, check-canon's marker) -- and, since
# the same night, the STANDARDS §2B pre-spawn checkpoint (spawn-checkpoint.sh begin/verify + spawn-guard.sh).
#
# WHY. The atoms-lint gates live in shell hooks that nobody watches, and a fix proven by a throwaway
# scratch harness dies with the session that wrote it. This is that harness made portable and committed,
# so the next change to a save path re-runs the whole suite instead of re-deriving it.
#
# ISOLATION (top-level test lines pasted into a tool once ran in a real worktree -- never again): runs ONLY
# in a fresh mktemp dir -- a scratch clone of the repo under test + a LOCAL
# bare origin, push URL pinned to that bare, HOME/USERPROFILE sandboxed (python's expanduser reads
# USERPROFILE on Windows). The real origin is never contacted. It must be run as a FILE (set -e is
# honored here, not by top-level lines pasted into a tool). The CANDIDATE scripts are the repo's
# WORKING-TREE copies, so uncommitted edits get tested before they ship.
#
# CONTENT-INDEPENDENT: it seeds its own synthetic fixture (prefix 'tst', memory/zz-gates-*.md) into the
# scratch clone, so it never depends on real canon facts -- the same file runs on canon and on the kit.
# That includes transcripts/rendered: the clone's copy is swapped for one clean fixture file (with the real
# tree, one HOT file or a too-long path failed T14/T31-T34 and looked like a spawn-checkpoint bug).
# Whether the REAL rendered/ scans clean is its own clearly named check (T0b), since a HOT file there
# blocks the live archive commit and spawn-checkpoint begin.
#
# Usage:  bash setup/test-save-gates.sh [REPO]     (default: the repo this script lives in)
#         KEEP=1 bash setup/test-save-gates.sh      (keep the scratch dir for inspection)
# Exit:   0 = all passed, 1 = a check failed or setup aborted. Runtime ~1-2 min on Windows.
set -euo pipefail

SRC="$(cd "${1:-$(dirname "$0")/..}" && pwd)"
[ -f "${SRC}/setup/session-autosave.sh" ] || { echo "ABORT: ${SRC} has no setup/session-autosave.sh"; exit 1; }
PY=""
for c in "py -3" python3 python; do
  if $c -c "import sys" >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "${PY}" ] || { echo "ABORT: no python -- the gate under test needs one"; exit 1; }

REAL_HOME="${HOME}"
T="$(mktemp -d "${TMPDIR:-/tmp}/save-gates.XXXXXX")"
command -v cygpath >/dev/null 2>&1 && T="$(cygpath -m "${T}")"   # C:/... form: bash, git and python all agree
case "${T}" in */save-gates.*) ;; *) echo "ABORT: unexpected scratch path ${T}"; exit 1 ;; esac
cleanup() { [ "${KEEP:-0}" = 1 ] && echo "scratch kept: ${T}" || rm -rf "${T}"; }
trap cleanup EXIT
mkdir -p "${T}/home"
cd "${T}" || { echo "ABORT: cd ${T}"; exit 1; }

[ -f "${REAL_HOME}/.gitconfig" ] && export GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-${REAL_HOME}/.gitconfig}"
export HOME="${T}/home"
if command -v cygpath >/dev/null 2>&1; then export USERPROFILE; USERPROFILE="$(cygpath -w "${HOME}")"; else export USERPROFILE="${HOME}"; fi
BARE="${T}/origin.git"
R="${HOME}/Claude-Memory"

# ── setup: bare origin + scratch clone, push pinned, candidate scripts + synthetic fixture installed ──
git clone -q --bare -c core.longpaths=true "${SRC}" "${BARE}"
git -C "${BARE}" config --unset remote.origin.url 2>/dev/null || true
# Pin the bare's HEAD to main: a bare clone inherits the SOURCE's HEAD, so running this from a branch
# (e.g. a kit port branch) made every plain clone of it -- T0's lint check included -- check out that
# branch's OLD tip instead of the main under test.
git -C "${BARE}" symbolic-ref HEAD refs/heads/main
git clone -q -c core.longpaths=true -b main "${BARE}" "${R}"
cd "${R}" || { echo "ABORT: cd ${R}"; exit 1; }
git remote set-url origin "${BARE}"
git remote set-url --push origin "${BARE}"
[ "$(git remote get-url --push origin)" = "${BARE}" ] || { echo "ABORT: push URL not pinned to the scratch bare"; exit 1; }
git config user.name "Save-Gates Test"; git config user.email "save-gates@example.invalid"; git config core.longpaths true

# transcripts/render-session.py is a candidate too: transcript-autosave's fail-closed scan runs it, so testing
# HEAD's copy instead of the working tree's hid a scanner false positive (the 10-08..10-17 archive stall) as
# one "pre-existing" T14 failure, and later made spawn-checkpoint's new commit check look broken.
for f in setup/session-autosave.sh setup/atoms-lint.py setup/check-canon.sh setup/transcript-autosave.sh setup/canon-save.sh \
         setup/spawn-checkpoint.sh setup/spawn-guard.sh transcripts/render-session.py \
         transcripts/redaction-test.py transcripts/drift-test.py .gitignore .claude/settings.json; do
  [ -f "${SRC}/${f}" ] && cp "${SRC}/${f}" "${R}/${f}"
done
# The scratch clone's rendered/ is a synthetic clean fixture, not the repo's real archive (see header).
git rm -rq --ignore-unmatch transcripts/rendered
mkdir -p transcripts/rendered
printf '# zz-gates rendered fixture
A clean, synthetic rendered transcript.
' > transcripts/rendered/zz-gates-fixture.md
printf '# zz-gates-src (test-save-gates fixture)\nSynthetic source file for the tst atoms.\n' > memory/zz-gates-src.md
printf '# zz-gates-ref (test-save-gates fixture)\nThis file cites tst-01.\n' > memory/zz-gates-ref.md
printf '# zz-gates-probe (test-save-gates fixture)\n' > memory/zz-gates-probe.md
printf '%s\n' '{"id": "tst-01", "claim": "fixture atom one", "src": "zz-gates-src", "date": "2026-09-30", "conf": "high"}' \
              '{"id": "tst-02", "claim": "fixture atom two", "src": "zz-gates-src", "date": "2026-09-30", "conf": "high"}' >> memory/atoms.jsonl
git add -A
git commit -qm "test: candidate scripts + synthetic fixture"
git push -q origin main
BASE="$(git rev-parse HEAD)"
echo "repo under test: ${SRC}"
echo "scratch clone:   ${R}  (base ${BASE:0:7}, push -> scratch bare)"

# ── helpers ───────────────────────────────────────────────────────────────────────────────────────
PASS=0; FAILN=0; MAXMS=0; MS=0; RC=0
ok()  { PASS=$((PASS+1));  echo "  ok   $*"; }
bad() { FAILN=$((FAILN+1)); echo "  FAIL $*"; }
check() { local d="$1"; shift; if "$@"; then ok "${d}"; else bad "${d}"; fi; }
not() { ! "$@"; }
in_scratch() { [ "$(git rev-parse --show-toplevel)" = "${R}" ] || { echo "ABORT: left the scratch clone"; exit 1; }; }
reset_state() {
  cd "${R}" || { echo "ABORT: cd"; exit 1; }
  in_scratch
  git -C "${BARE}" update-ref refs/heads/main "${BASE}"
  git checkout -q -f main
  git reset -q --hard "${BASE}"
  git clean -qfd
  git fetch -q origin
  rm -f .git/autosave-msg .git/autosave-FAILED .git/autosave-HELD .git/atoms-lint-FAILED
}
autosave() {   # runs the Stop hook; the atoms-lint mirror deliberately persists (exercises the incremental sync)
  local s="${1:-${R}/setup/session-autosave.sh}" t0 t1
  in_scratch
  t0=$(date +%s%N); RC=0; bash "${s}" 2> "${T}/stderr.txt" || RC=$?; t1=$(date +%s%N)
  MS=$(( (t1-t0)/1000000 )); [ "${MS}" -gt "${MAXMS}" ] && MAXMS=${MS}
  echo "    (autosave rc=${RC}, ${MS} ms) $(tr -d '\r' < "${T}/stderr.txt" | head -c 240)"
}
bare_head()  { git -C "${BARE}" rev-parse main; }
pushed()     { [ "$(bare_head)" = "$(git rev-parse HEAD)" ]; }
origin_has() { git -C "${BARE}" grep -q -F -e "$1" main -- memory; }   # fixtures live in memory/; this file itself contains the probe strings
head_has()   { git grep -q -F -e "$1" HEAD -- memory; }
dirty()      { [ -n "$(git -c core.quotePath=false status --porcelain -- "$1")" ]; }
marker()     { [ -f .git/atoms-lint-FAILED ]; }
marker_has() { grep -q -F -e "$1" .git/atoms-lint-FAILED; }
nothing_staged() { git diff --cached --quiet; }
origin_lints_clean() {
  rm -rf "${T}/verify"; git clone -q -c core.longpaths=true "${BARE}" "${T}/verify"
  $PY "${R}/setup/atoms-lint.py" --root "${T}/verify" "${T}/verify/memory/atoms.jsonl" > "${T}/verify.out" 2>&1
}
cc_json_ok() {   # check-canon output parses as JSON and its context contains every given string
  bash setup/check-canon.sh > "${T}/cc.json"
  $PY - "${T}/cc.json" "$@" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))["hookSpecificOutput"]["additionalContext"]
sys.exit(0 if all(s in m for s in sys.argv[2:]) else 1)
PYEOF
}
ATOM_OK='{"id": "tst-90", "claim": "fixture atom ninety", "src": "zz-gates-src", "date": "2026-09-30", "conf": "high"}'
ATOM_BAD='{"id": "bad_id", "claim": "malformed id", "src": "zz-gates-src", "date": "2026-09-30", "conf": "high"}'
ATOM_CRASH='{"id": 5, "claim": "an int id crashes the lint", "src": "zz-gates-src", "date": "2026-09-30", "conf": "high"}'
DANGLE='gates-probe dangling ref tst-999'
good_edit() { printf 'harmless edit %s\n' "$1" >> memory/zz-gates-probe.md; }
add_dangling() { printf '%s\n' "${DANGLE}" >> memory/zz-gates-ref.md; }

echo; echo "== T0 baseline lints clean (else every result below is meaningless)"
if origin_lints_clean; then ok "base lints clean"; else cat "${T}/verify.out"; echo "ABORT: repo under test fails atoms-lint at HEAD"; exit 1; fi

echo; echo "== T0b the CANDIDATE scanner: its own tests pass, and the REAL repo's rendered/ scans clean"
# redaction-test pins what must mask / survive / rescan clean (when no gate ran it, a pass/pw relaxation
# shipped green while it spared real credentials). The real-tree scan is a LIVE-SYSTEM check:
# a HOT (rc 1) or unreadable (rc 2) file there means the archive commit and spawn-checkpoint begin are
# blocked on the real box right now -- it is not a failure of the scripts the T-tests below exercise.
check "redaction-test.py passes" $PY transcripts/redaction-test.py
if [ -f transcripts/drift-test.py ]; then
  RD=0; $PY transcripts/drift-test.py > "${T}/drift.out" 2>&1 || RD=$?
  [ "${RD}" = 0 ] || tail -20 "${T}/drift.out"     # the scratch dir is deleted on exit: show why, now
  check "drift-test.py passes" [ "${RD}" = 0 ]
fi
if [ -d "${SRC}/transcripts/rendered" ]; then
  RS=0; $PY transcripts/render-session.py scan "${SRC}/transcripts/rendered" > "${T}/realscan.out" 2>&1 || RS=$?
  # scan masks its own context lines, so printing them cannot re-leak a value
  [ "${RS}" = 0 ] || grep -E '‼|UNREADABLE|likely secret' "${T}/realscan.out" | head -20
  check "real ${SRC##*/}/transcripts/rendered scans clean with the candidate scanner (rc ${RS}; 1=HOT, 2=unreadable)" [ "${RS}" = 0 ]
fi

echo; echo "== T1 .md-only DANGLING ref + an unrelated good edit -> bad .md held, rest pushed"
reset_state; add_dangling; good_edit T1; autosave
check "rc 0" [ "${RC}" = 0 ]
check "bad .md held (still dirty)" dirty memory/zz-gates-ref.md
check "work not lost (working tree keeps the ref)" grep -q -F "${DANGLE}" memory/zz-gates-ref.md
check "dangling ref NOT in HEAD" not head_has "${DANGLE}"
check "dangling ref NOT on origin" not origin_has "${DANGLE}"
check "good edit committed + pushed" bash -c "git grep -q 'harmless edit T1' HEAD && [ \"\$(git -C '${BARE}' rev-parse main)\" = \"\$(git rev-parse HEAD)\" ]"
check "nothing left staged" nothing_staged
check "marker names the held file + reason" bash -c "grep -q 'memory/zz-gates-ref.md' .git/atoms-lint-FAILED && grep -q 'tst-999' .git/atoms-lint-FAILED"
check "commit carries the HELD trailer" bash -c "git log -1 --format=%B | grep -q 'HELD BACK, failed atoms-lint'"
check "check-canon: valid JSON, announces gate, keeps the '/' in paths" cc_json_ok "ATOMS-LINT GATE" "1x memory/zz-gates-ref.md"
check "origin tip lints clean" origin_lints_clean

echo; echo "== T2 dangling ref is the ONLY change (+ authored hint) -> nothing commits, hint kept; T3 revert -> marker clears"
reset_state; add_dangling; printf 'test: authored hint\n' > .git/autosave-msg; autosave
check "HEAD + origin unchanged" bash -c "[ \"\$(git rev-parse HEAD)\" = '${BASE}' ] && [ \"\$(git -C '${BARE}' rev-parse main)\" = '${BASE}' ]"
check "bad .md still dirty" dirty memory/zz-gates-ref.md
check "marker written" marker
check "hint preserved (it describes the held work)" test -s .git/autosave-msg
git checkout -q -- memory/zz-gates-ref.md; autosave
check "clean tree + HEAD lints clean -> stale marker cleared" not marker

echo; echo "== T4 bad atom (malformed id) + good edit -> atoms.jsonl held (F-A), rest pushed"
reset_state; printf '%s\n' "${ATOM_BAD}" >> memory/atoms.jsonl; good_edit T4; autosave
check "atoms.jsonl held" dirty memory/atoms.jsonl
check "bad atom NOT on origin" not bash -c "git -C '${BARE}' show main:memory/atoms.jsonl | grep -q bad_id"
check "good edit pushed" pushed
check "marker names atoms.jsonl" marker_has "memory/atoms.jsonl"
check "origin tip lints clean" origin_lints_clean

echo; echo "== T5 CASCADE: atoms.jsonl (valid tst-90 + bad atom) held -> the .md citing tst-90 must be held too"
reset_state; printf '%s\n%s\n' "${ATOM_OK}" "${ATOM_BAD}" >> memory/atoms.jsonl
printf 'see tst-90 for the new rule\n' >> memory/zz-gates-ref.md; good_edit T5; autosave
check "atoms.jsonl held" dirty memory/atoms.jsonl
check "citing .md held (only an INDEX lint catches this)" dirty memory/zz-gates-ref.md
check "citation NOT on origin" not origin_has "see tst-90"
check "good edit pushed" pushed
check "origin tip lints clean" origin_lints_clean

echo; echo "== T6 all clean: valid tst-90 + .md citing it -> F-E path-scoped atoms commit + .md commit, pushed"
reset_state; printf '%s\n' "${ATOM_OK}" >> memory/atoms.jsonl; printf 'see tst-90 for the new rule\n' >> memory/zz-gates-ref.md; autosave
check "tree clean" test -z "$(git status --porcelain)"
check "2 commits, the first touching ONLY atoms.jsonl" bash -c "[ \"\$(git rev-list --count '${BASE}'..HEAD)\" = 2 ] && [ \"\$(git show --name-only --format= HEAD~1)\" = memory/atoms.jsonl ]"
check "pushed, no marker" bash -c "[ \"\$(git -C '${BARE}' rev-parse main)\" = \"\$(git rev-parse HEAD)\" ] && [ ! -f .git/atoms-lint-FAILED ]"

echo; echo "== T7 atoms-only valid change -> F-E commit pushed via the nothing-left-staged exit"
reset_state; printf '%s\n' "${ATOM_OK}" >> memory/atoms.jsonl; autosave
check "one atoms-only commit, pushed, no marker" bash -c "[ \"\$(git rev-list --count '${BASE}'..HEAD)\" = 1 ] && [ \"\$(git -C '${BARE}' rev-parse main)\" = \"\$(git rev-parse HEAD)\" ] && [ ! -f .git/atoms-lint-FAILED ]"

echo; echo "== T8 plain edit -> commit + push, no marker"
reset_state; good_edit T8; autosave
check "pushed, clean, no marker" bash -c "[ \"\$(git -C '${BARE}' rev-parse main)\" = \"\$(git rev-parse HEAD)\" ] && [ -z \"\$(git status --porcelain)\" ] && [ ! -f .git/atoms-lint-FAILED ]"

echo; echo "== T9 staged delete of an atom's src .md (unresolved src) -> the delete is held"
reset_state; git rm -q memory/zz-gates-src.md; good_edit T9; autosave
check "delete NOT committed" git cat-file -e HEAD:memory/zz-gates-src.md
check "file still deleted on disk (work kept)" not test -e memory/zz-gates-src.md
check "good edit pushed" pushed
check "origin tip lints clean" origin_lints_clean

echo; echo "== T10 atom REMOVED from under an unchanged .md (tst-01) -> last resort holds atoms.jsonl"
reset_state; grep -v '"id": "tst-01"' memory/atoms.jsonl > "${T}/atoms.tmp"; cp "${T}/atoms.tmp" memory/atoms.jsonl; good_edit T10; autosave
check "atoms.jsonl held" dirty memory/atoms.jsonl
check "good edit pushed" pushed
check "origin tip lints clean" origin_lints_clean

echo; echo "== T11 lint CRASH (int id) -> atoms.jsonl held (last resort), marker says CRASHED"
reset_state; printf '%s\n' "${ATOM_CRASH}" >> memory/atoms.jsonl; good_edit T11; autosave
check "atoms.jsonl held" dirty memory/atoms.jsonl
check "good edit pushed" pushed
check "marker says lint CRASHED" marker_has "lint CRASHED"

echo; echo "== T12 held paths with a space and non-ASCII"
reset_state
printf 'gates ref tst-997\n' > "memory/zz gates space.md"
printf 'gates ref tst-996\n' > "memory/zz-gates-café.md"
good_edit T12; autosave
check "spaced file held (not in HEAD)" not git cat-file -e "HEAD:memory/zz gates space.md" 2>/dev/null
check "non-ASCII file held (not in HEAD)" not git cat-file -e "HEAD:memory/zz-gates-café.md" 2>/dev/null
check "both still on disk" test -f "memory/zz gates space.md" -a -f "memory/zz-gates-café.md"
check "good edit pushed" pushed

echo; echo "== T13 failure PRE-EXISTING on origin -> commit + push anyway, marker says so"
reset_state; printf 'gates bad base tst-998\n' >> memory/zz-gates-ref.md
git commit -qam "test: bad base already on origin"; git push -q origin main
good_edit T13; autosave
check "pushed anyway" pushed
check "marker: pre-existing, not WITHHELD" bash -c "grep -q 'pre-existing' .git/atoms-lint-FAILED && ! grep -q 'PUSH WITHHELD' .git/atoms-lint-FAILED"

echo; echo "== T14 failure in a LOCAL-ONLY commit -> PUSH WITHHELD; transcript-autosave honors it; fix clears it"
reset_state; printf 'gates local-only bad tst-998\n' >> memory/zz-gates-ref.md
git commit -qam "test: raw local commit with a dangling ref"
good_edit T14; autosave
check "good edit committed locally, origin UNCHANGED" bash -c "git grep -q 'harmless edit T14' HEAD && [ \"\$(git -C '${BARE}' rev-parse main)\" = '${BASE}' ]"
check "marker says PUSH WITHHELD" marker_has "PUSH WITHHELD"
check "check-canon warns not to raw-push" cc_json_ok "do NOT raw-push"
mkdir -p transcripts/rendered; printf '# gates rendered probe\nhello\n' > transcripts/rendered/zz-gates.md
bash setup/transcript-autosave.sh 2>/dev/null || true
check "transcript-autosave committed, did NOT push" bash -c "git log -1 --format=%s | grep -q 'transcript archive' && [ \"\$(git -C '${BARE}' rev-parse main)\" = '${BASE}' ]"
autosave
check "clean tree: marker KEPT while HEAD still fails" marker
grep -v 'tst-998' memory/zz-gates-ref.md > "${T}/ref.tmp"; cp "${T}/ref.tmp" memory/zz-gates-ref.md; autosave
check "after the fix: pushed, marker cleared" bash -c "[ \"\$(git -C '${BARE}' rev-parse main)\" = \"\$(git rev-parse HEAD)\" ] && [ ! -f .git/atoms-lint-FAILED ]"
check "origin tip lints clean" origin_lints_clean

echo; echo "== T15 round cap cut short (script copy, cap=1, on the 2-round cascade) -> PUSH WITHHELD"
sed 's/"${rounds}" -lt 8/"${rounds}" -lt 1/; s/"${rounds}" -ge 8/"${rounds}" -ge 1/' setup/session-autosave.sh > "${T}/cap1.sh"
check "cap patch applied twice" [ "$(grep -c 'rounds}" -[lg][te] 1' "${T}/cap1.sh")" = 2 ]
reset_state; printf '%s\n%s\n' "${ATOM_OK}" "${ATOM_BAD}" >> memory/atoms.jsonl
printf 'see tst-90 for the new rule\n' >> memory/zz-gates-ref.md; good_edit T15; autosave "${T}/cap1.sh"
check "origin UNCHANGED, marker PUSH WITHHELD" bash -c "[ \"\$(git -C '${BARE}' rev-parse main)\" = '${BASE}' ] && grep -q 'PUSH WITHHELD' .git/atoms-lint-FAILED"

echo; echo "== T16 authored hint + partial hold -> commit uses the hint + HELD trailer, hint consumed"
reset_state; printf 'test: authored subject\n\nbody line\n' > .git/autosave-msg; add_dangling; good_edit T16; autosave
check "subject is the hint" [ "$(git log -1 --format=%s)" = "test: authored subject" ]
check "HELD trailer names the file" bash -c "git log -1 --format=%B | grep -q 'HELD BACK, failed atoms-lint (left uncommitted): memory/zz-gates-ref.md'"
check "hint consumed" not test -e .git/autosave-msg

if [ -f setup/canon-save.sh ]; then
  echo; echo "== T17 canon-save REFUSES a dangling-ref save, then the Stop hook holds just that file"
  reset_state; add_dangling; good_edit T17
  CS=0; bash setup/canon-save.sh "test: must be refused" > "${T}/cs.out" 2>&1 || CS=$?
  check "canon-save refused, index untouched, nothing pushed" bash -c "[ '${CS}' != 0 ] && git diff --cached --quiet && [ \"\$(git -C '${BARE}' rev-parse main)\" = '${BASE}' ]"
  autosave
  check "Stop hook: bad .md held, not on origin, rest pushed" bash -c "[ -n \"\$(git status --porcelain -- memory/zz-gates-ref.md)\" ] && ! git -C '${BARE}' grep -q -F -e '${DANGLE}' main -- memory && [ \"\$(git -C '${BARE}' rev-parse main)\" = \"\$(git rev-parse HEAD)\" ]"
fi

echo; echo "== T18 bogus tree-id (e.g. a gc'd tree) -> full re-export, still catches the ref"
reset_state; mkdir -p .git/atoms-lint-snap; printf '0000000000000000000000000000000000000bad\n' > .git/atoms-lint-snap/tree-id
add_dangling; good_edit T18; autosave
check "bad .md held, rest pushed" bash -c "[ -n \"\$(git status --porcelain -- memory/zz-gates-ref.md)\" ] && [ \"\$(git -C '${BARE}' rev-parse main)\" = \"\$(git rev-parse HEAD)\" ]"
check "tree-id = current index tree" [ "$(cat .git/atoms-lint-snap/tree-id 2>/dev/null)" = "$(git write-tree)" ]

echo; echo "== T19 incremental mirror == a fresh export of the index (after every run above)"
rm -rf "${T}/fresh"; mkdir -p "${T}/fresh"
git ls-files -z -- '*.md' ':(exclude)transcripts/*.md' memory/atoms.jsonl transcripts/render-session.py > "${T}/fresh.list"
git checkout-index -z --stdin --prefix="${T}/fresh/" < "${T}/fresh.list"
check "mirror identical to a fresh export" bash -c "diff -r -q '${T}/fresh' .git/atoms-lint-snap/tree >/dev/null 2>&1"

echo; echo "== T20 the default-root lint (canon-save/dr-check mode) never walks the mirror inside .git/"
reset_state; mkdir -p .git/atoms-lint-snap/tree/memory
printf 'gates ref tst-995 only inside .git\n' > .git/atoms-lint-snap/tree/memory/zz-only-in-mirror.md
check "default-root lint passes" bash -c "$PY setup/atoms-lint.py >/dev/null"
rm -f .git/atoms-lint-snap/tree/memory/zz-only-in-mirror.md

echo; echo "== T21 no python on PATH -> proceeds unlinted (the pre-existing rule)"
NOPY=""
for t in bash git date rm mkdir cat tr grep tail; do
  d="$(dirname "$(command -v "${t}")")"; case ":${NOPY}:" in *":${d}:"*) ;; *) NOPY="${NOPY:+${NOPY}:}${d}" ;; esac
done
if PATH="${NOPY}" command -v py >/dev/null 2>&1 || PATH="${NOPY}" command -v python3 >/dev/null 2>&1 \
   || PATH="${NOPY}" command -v python >/dev/null 2>&1; then
  echo "  skip (python shares a directory with git/coreutils here -- can't hide it)"
else
  reset_state; good_edit T21; PATH="${NOPY}" bash "${R}/setup/session-autosave.sh" 2>/dev/null || true
  check "committed + pushed without python" pushed
fi

echo; echo "== T22 off-main bailout still skips + drops the HELD marker"
reset_state; git checkout -q -b gates-side; good_edit T22; autosave
check "nothing committed off main, HELD marker written" bash -c "[ \"\$(git rev-parse HEAD)\" = '${BASE}' ] && [ -f .git/autosave-HELD ]"
git checkout -q -f main

if [ -f setup/spawn-checkpoint.sh ] && [ -f setup/spawn-guard.sh ]; then
  # Stamps are per session: begin/verify key on CLAUDE_CODE_SESSION_ID, the guard on its payload's
  # session_id. The test session's id IS its transcript's stem, as in Claude Code (<slug>/<session_id>.jsonl).
  SJID="0a1b2c3d-0000-4000-8000-000000000001"; OTHER="0a1b2c3d-0000-4000-8000-0000000000bb"
  export CLAUDE_CODE_SESSION_ID="${SJID}"
  PL='{"tool_name":"mcp__ccd_session__start_session","session_id":"'"${SJID}"'"}'
  OKS=".git/spawn-checkpoint-OK.${SJID}"; BGS=".git/spawn-checkpoint-begin.${SJID}"
  guard() { G=0; printf '%s' "$1" | bash setup/spawn-guard.sh 2> "${T}/guard.err" || G=$?; }

  echo; echo "== T30 §2B spawn guard: blocks without a checkpoint, allows a fresh one FOR THIS SESSION, re-blocks a stale/garbled/other-session one"
  reset_state
  guard "${PL}"
  check "no stamp -> BLOCK (exit 2) citing §2B" bash -c "[ '${G}' = 2 ] && grep -q 'STANDARDS §2B' '${T}/guard.err'"
  printf '%s OK test\n' "$(date +%s)" > "${OKS}"
  guard "${PL}"; check "fresh stamp for this session -> allow" [ "${G}" = 0 ]
  guard "${PL/${SJID}/${OTHER}}"; check "another session's stamp (e.g. the parent's) does NOT arm this one" [ "${G}" = 2 ]
  guard '{"session_id":"'"${OTHER}"'","tool_name":"mcp__ccd_session__start_session","tool_input":{"session_id":"'"${SJID}"'"}}'
  check "a session_id inside tool_input cannot borrow another session's stamp" [ "${G}" = 2 ]
  guard '{}'; check "a payload without session_id ignores per-session stamps" [ "${G}" = 2 ]
  printf '%s OK test\n' "$(( $(date +%s) - 4000 ))" > "${OKS}"
  guard "${PL}"; check "stamp over 60 min -> BLOCK" [ "${G}" = 2 ]
  printf 'garbage\n' > "${OKS}"
  guard "${PL}"; check "garbled stamp -> BLOCK" [ "${G}" = 2 ]
  rm -f "${OKS}"

  echo; echo "== T30b the settings.json matcher routes every session-creating tool to spawn-guard"
  # T30 pipes payloads straight into the script, so it cannot see the matcher -- which is how start_session
  # (and then hand_off_to_session) went unguarded while T30 stayed green. Claude Code tests a non-simple
  # matcher as an UNANCHORED regex against the tool name; re.search is the same test.
  check "matcher covers spawn_task, start_session, hand_off_to_session -- and no read-only session tools" $PY - .claude/settings.json <<'PYEOF'
import json, re, sys
hooks = json.load(open(sys.argv[1], encoding="utf-8")).get("hooks", {}).get("PreToolUse", [])
ms = [h.get("matcher", "") for h in hooks if any("spawn-guard.sh" in x.get("command", "") for x in h.get("hooks", []))]
m = re.compile(ms[0]) if len(ms) == 1 else None
must = ["mcp__ccd_session__spawn_task", "mcp__ccd_session__start_session", "mcp__ccd_session__hand_off_to_session"]
never = ["mcp__ccd_session__mark_chapter", "mcp__ccd_session__dismiss_task", "mcp__ccd_session__list_start_targets", "Bash"]
sys.exit(0 if m and all(m.search(t) for t in must) and not any(m.search(t) for t in never) else 1)
PYEOF

  echo; echo "== T31 §2B checkpoint: begin on a box with NO mirror -> archives locally, prompts to connect the mirror, exit 3"
  SLUGD="${HOME}/.claude/projects/gates-slug"; mkdir -p "${SLUGD}"
  SJ="${SLUGD}/${SJID}.jsonl"
  live_turn() { printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"gates probe %s"}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "${SJ}"; }
  reset_state; rm -f "${BGS}" transcripts/mirror-target.txt
  live_turn a; B=0; bash setup/spawn-checkpoint.sh begin > "${T}/b.out" 2> "${T}/b.err" || B=$?
  check "exit 3 (mirror pending)" [ "${B}" = 3 ]
  check "prompt names mirror-target.txt and says Claude never types the password" bash -c "grep -q 'mirror-target.txt' '${T}/b.err' && grep -q 'never types' '${T}/b.err'"
  check "raw archived locally anyway" bash -c "ls transcripts/raw/*.gz >/dev/null 2>&1"
  check "begin stamp records mirror=pending" grep -q 'mirror=pending' "${BGS}"
  V=0; bash setup/spawn-checkpoint.sh verify > /dev/null 2> "${T}/v.err" || V=$?
  check "verify refuses while the mirror is pending" bash -c "[ '${V}' = 1 ] && grep -q 'mirror is still pending' '${T}/v.err'"

  echo; echo "== T32 begin with a reachable mirror -> mirrored + CRC-verified, stamp ok"
  mkdir -p "${T}/nas/ClaudeArchive"; printf '%s\n' "${T}/nas/ClaudeArchive" > transcripts/mirror-target.txt
  live_turn b; B=0; bash setup/spawn-checkpoint.sh begin > "${T}/b.out" 2> "${T}/b.err" || B=$?
  check "exit 0" [ "${B}" = 0 ]
  check "raw .gz landed on the mirror" bash -c "ls '${T}/nas/ClaudeArchive/raw/'*.gz >/dev/null 2>&1"
  check "stamp mirror=ok" grep -q 'mirror=ok' "${BGS}"
  check "this session's own rendered transcript is tracked in HEAD" bash -c "git ls-files transcripts/rendered | grep -q 'session-0a1b2c3d'"

  echo; echo "== T33 verify enforces steps 2+3: a commit, a narrative change, a NEW atom tied to it, pushed"
  V=0; bash setup/spawn-checkpoint.sh verify > /dev/null 2> "${T}/v.err" || V=$?
  check "no commit since begin -> refuse" bash -c "[ '${V}' = 1 ] && grep -q 'no commit since begin' '${T}/v.err'"
  printf 'spawn context: probe\n' >> memory/zz-gates-probe.md
  printf '%s\n' '{"id": "tst-91", "claim": "fixture spawn atom", "src": "zz-gates-src", "date": "2026-09-30", "conf": "high"}' >> memory/atoms.jsonl
  git add -A -- memory; git commit -qm "test: spawn context, atom src NOT among the changed files"; git push -q origin main
  V=0; bash setup/spawn-checkpoint.sh verify > /dev/null 2> "${T}/v.err" || V=$?
  check "atom not tied to the updated files -> refuse" bash -c "[ '${V}' = 1 ] && grep -q 'none has its src' '${T}/v.err'"
  printf 'spawn context: why this spawn exists\n' >> memory/zz-gates-src.md
  V=0; bash setup/spawn-checkpoint.sh verify > /dev/null 2> "${T}/v.err" || V=$?
  check "dirty tree -> refuse" bash -c "[ '${V}' = 1 ] && grep -q 'tree is dirty' '${T}/v.err'"
  git commit -qam "test: spawn context in the atom's src"
  V=0; bash setup/spawn-checkpoint.sh verify > /dev/null 2> "${T}/v.err" || V=$?
  check "unpushed -> refuse" bash -c "[ '${V}' = 1 ] && grep -q 'not in origin/main' '${T}/v.err'"
  git push -q origin main
  V=0; bash setup/spawn-checkpoint.sh verify > "${T}/v.out" 2> "${T}/v.err" || V=$?
  check "tied atom + pushed -> VERIFIED" bash -c "[ '${V}' = 0 ] && grep -q 'tst-91' '${T}/v.out'"
  guard "${PL}"; check "guard now ALLOWS this session's spawn" [ "${G}" = 0 ]
  guard "${PL/${SJID}/${OTHER}}"; check "...but still BLOCKS another session (a child in the same folder)" [ "${G}" = 2 ]
  check "verify consumed the begin stamp (one begin arms the guard once)" not test -e "${BGS}"
  V=0; bash setup/spawn-checkpoint.sh verify > /dev/null 2> "${T}/v.err" || V=$?
  check "a second verify without a new begin refuses" bash -c "[ '${V}' = 1 ] && grep -q 'no begin stamp' '${T}/v.err'"

  echo; echo "== T34 --mirror-waived needs the user's reason; with one, the waiver is recorded"
  rm -f transcripts/mirror-target.txt; live_turn c
  B=0; bash setup/spawn-checkpoint.sh begin --mirror-waived > /dev/null 2>&1 || B=$?
  check "waiver without a reason -> refuse" [ "${B}" = 1 ]
  live_turn d; B=0; bash setup/spawn-checkpoint.sh begin --mirror-waived "user: off-LAN tonight" > /dev/null 2>&1 || B=$?
  check "waiver with a reason -> ok, recorded" bash -c "[ '${B}' = 0 ] && grep -q 'waived: user: off-LAN tonight' '${BGS}'"
  check "begin disarms an old OK stamp" not test -e "${OKS}"

  echo; echo "== T35 a REFUSED archive commit: begin dies naming it and leaves NO begin stamp for verify"
  check "(setup) T34's begin left a stamp" test -f "${BGS}"
  git checkout -q -b gates-hold; live_turn e      # off main -> transcript-autosave renders, then holds the commit
  B=0; bash setup/spawn-checkpoint.sh begin --mirror-waived "test" > /dev/null 2> "${T}/b.err" || B=$?
  check "held commit -> exit 1, 'did NOT commit transcripts/rendered'" bash -c "[ '${B}' = 1 ] && grep -q 'did NOT commit transcripts/rendered' '${T}/b.err'"
  check "the earlier begin stamp is gone" not test -e "${BGS}"
  V=0; bash setup/spawn-checkpoint.sh verify > /dev/null 2> "${T}/v.err" || V=$?
  check "verify refuses (no begin stamp to honor)" bash -c "[ '${V}' = 1 ] && grep -q 'no begin stamp' '${T}/v.err'"
  git checkout -q -f main; git clean -qfd -- transcripts/rendered; rm -f .git/autosave-HELD

  echo; echo "== T37 a render that CRASHES leaves rendered/ clean -- begin still dies (prove THIS session's file)"
  printf '{"type":"ai-title","aiTitle":"Crash probe title"}\n' >> "${SJ}"; live_turn i
  NEWNAME=$($PY - "${SJ}" <<'PYEOF'
import importlib.util, sys
from pathlib import Path
s = importlib.util.spec_from_file_location("rs", "transcripts/render-session.py"); rs = importlib.util.module_from_spec(s); s.loader.exec_module(rs)
m = rs.session_meta(Path(sys.argv[1])); st = rs.local_time(m["first"])
print(f"{st:%Y-%m-%d}-{rs.slugify(rs.display_title(m), m['session_id'][:8])}.md")
PYEOF
)
  mkdir -p "transcripts/rendered/${NEWNAME}"      # the render's write target is a directory -> render crashes
  sleep 1
  B=0; bash setup/spawn-checkpoint.sh begin --mirror-waived "test" > "${T}/b.out" 2> "${T}/b.err" || B=$?
  check "render crashed, tree clean -> begin exit 1 'NOT re-rendered'" bash -c "[ '${B}' = 1 ] && grep -q 'NOT re-rendered' '${T}/b.err'"
  grep -q 'NOT re-rendered' "${T}/b.err" || { echo "    begin rc=${B}, stderr:"; sed -n '1,8p' "${T}/b.err"; cat "${T}/b.out"; ls -la --time-style=+%T.%N transcripts/rendered | head; $PY -c "import json;print(json.load(open('transcripts/.render-state.json'))['${SJID}'])"; git log -3 --format='%h %s' --stat | head -20; }
  rmdir "transcripts/rendered/${NEWNAME}"

  echo; echo "== T36 a session titled '...conflict...' reaches git; an output git IGNORES makes begin die"
  printf '{"type":"ai-title","aiTitle":"Fix the merge conflict in canon"}\n' >> "${SJ}"; live_turn g
  B=0; bash setup/spawn-checkpoint.sh begin --mirror-waived "test" > /dev/null 2> "${T}/b.err" || B=$?
  check "begin ok, and the conflict-titled render is TRACKED in HEAD" bash -c "[ '${B}' = 0 ] && git ls-files transcripts/rendered | grep -q 'merge-conflict'"
  printf '*probe-conflict*\n' > transcripts/rendered/.gitignore; git add transcripts/rendered/.gitignore; git commit -qm "test: ignore a probe"
  printf '{"type":"ai-title","aiTitle":"Probe conflict again"}\n' >> "${SJ}"; live_turn h
  B=0; bash setup/spawn-checkpoint.sh begin --mirror-waived "test" > /dev/null 2> "${T}/b.err" || B=$?
  check "an ignored output (clean tree, nothing committed) -> begin exit 1 'NOT tracked'" bash -c "[ '${B}' = 1 ] && grep -q 'NOT tracked' '${T}/b.err'"

  rm -rf "${SLUGD}" .git/spawn-checkpoint-begin.* .git/spawn-checkpoint-OK.*
  unset CLAUDE_CODE_SESSION_ID
fi

echo; echo "== T23 timing (warm mirror, plain edit)"
reset_state; good_edit T23a; autosave; good_edit T23b; autosave
check "warm plain-edit autosave under 10 s" [ "${MS}" -lt 10000 ]
check "every autosave run under 20 s (Stop hook timeout is 30 s)" [ "${MAXMS}" -lt 20000 ]

echo
echo "max autosave wall time: ${MAXMS} ms"
echo "RESULT: ${PASS} passed, ${FAILN} failed"
[ "${FAILN}" = 0 ]
