#!/usr/bin/env bash
# why.sh — query the REASONING tier of canon: commit message bodies.
#
# THE PROBLEM THIS SOLVES (Paul, 2026-08-02):
#   Canon has three tiers, and until now only two were reachable.
#     1. memory/*.md          — LOADED every session. Curated, topical, the conclusions.
#     2. transcripts/rendered — DURABLE but not loaded. The full conversation.
#     3. commit message bodies — RICHEST reasoning in the repo, and effectively WRITE-ONLY.
#   Tier 3 holds ~3,900 lines explaining *why* each change happened, what was rejected, and
#   which conclusions were later overturned. A session sees `git log --oneline` and gets none
#   of it. Paul: "You could dump a whole set of encyclopedia into my head, but I wouldn't know
#   what I don't know without a way to index and reference quickly."
#   So: don't promote it into the loaded tier (that bloats every session and buries the good
#   parts). Make it QUERYABLE instead. This script is the index, and it never goes stale
#   because it reads git directly.
#
# USAGE
#   ./setup/why.sh <keywords...>      search subjects AND bodies (case-insensitive)
#   ./setup/why.sh -f <path>          every reasoning-bearing commit that touched <path>
#   ./setup/why.sh -l [N]             index: the N richest commits (default 25)
#   ./setup/why.sh -s <hash>          full body of one commit
#   ./setup/why.sh -t <topic>         alias for search, kept for readability
#
# EXAMPLES
#   ./setup/why.sh bitlocker              # why did the encryption story change three times?
#   ./setup/why.sh -f memory/STANDARDS.md # why does canon say what it says?
#   ./setup/why.sh clock skew             # multiple words = AND, not a literal phrase
#   ./setup/why.sh 'Used.Space.Only'      # true phrase: dots stand in for the spaces
#   ./setup/why.sh -l 40                  # the 40 meatiest decisions in repo history

set -u
cd "$(dirname "$0")/.." || exit 1

MIN_BODY=5          # lines of real body text before a commit counts as "reasoning-bearing"
NOAUTO='--invert-grep --grep=^auto:'

c_hash=$'\033[33m'; c_date=$'\033[36m'; c_subj=$'\033[1m'; c_off=$'\033[0m'
[ -t 1 ] || { c_hash=''; c_date=''; c_subj=''; c_off=''; }

# body with the Co-Authored-By trailer and blank lines stripped, for counting
_bodylines() { git --no-pager log -1 --format='%b' "$1" | grep -v '^Co-Authored-By' | grep -c '[^[:space:]]'; }

_print_commit() {
  h="$1"; full="${2:-0}"
  d=$(git --no-pager log -1 --format='%ad' --date=short "$h")
  s=$(git --no-pager log -1 --format='%s' "$h")
  n=$(_bodylines "$h")
  printf '%s%s%s  %s%s%s  %s%s%s  (%s lines)\n' \
    "$c_hash" "$(git rev-parse --short "$h")" "$c_off" \
    "$c_date" "$d" "$c_off" "$c_subj" "$s" "$c_off" "$n"
  if [ "$full" = "1" ]; then
    git --no-pager log -1 --format='%b' "$h" | grep -v '^Co-Authored-By' | sed 's/^/    /'
  else
    git --no-pager log -1 --format='%b' "$h" | grep -v '^Co-Authored-By' \
      | grep '[^[:space:]]' | head -3 | sed 's/^/    /'
    [ "$n" -gt 3 ] && printf '    %s... (-s %s for the rest)%s\n' "$c_date" "$(git rev-parse --short "$h")" "$c_off"
  fi
  echo
}

# ---- modes -----------------------------------------------------------------
case "${1:-}" in
  -s)
    [ $# -ge 2 ] || { echo "usage: why.sh -s <hash>" >&2; exit 2; }
    _print_commit "$2" 1
    ;;

  -l)
    n="${2:-25}"
    echo "Richest reasoning in canon — top $n commits by body size:"
    echo
    # shellcheck disable=SC2086
    git --no-pager log $NOAUTO --format='%H' | while read -r h; do
      printf '%s %s\n' "$(_bodylines "$h")" "$h"
    done | sort -rn | head -"$n" | while read -r _ h; do _print_commit "$h"; done
    ;;

  -f)
    [ $# -ge 2 ] || { echo "usage: why.sh -f <path>" >&2; exit 2; }
    echo "Reasoning behind changes to: $2"
    echo
    found=0
    # shellcheck disable=SC2086
    for h in $(git --no-pager log $NOAUTO --format='%H' -- "$2"); do
      [ "$(_bodylines "$h")" -ge "$MIN_BODY" ] || continue
      _print_commit "$h"; found=1
    done
    [ "$found" = 0 ] && echo "  (no reasoning-bearing commits touched that path)"
    ;;

  ''|-h|--help)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    ;;

  *)
    [ "${1:-}" = "-t" ] && shift
    q="$*"
    echo "Commits whose subject or reasoning mentions: $q"
    echo
    found=0
    # NOTE: do NOT combine --invert-grep (the auto: filter) with the search --grep.
    # git applies --invert-grep to the UNION of every --grep pattern, so the two
    # together mean "matches neither" — it silently returns the exact inverse of
    # what you asked for. Caught by testing this on 'bitlocker' 2026-08-02.
    # So: grep first, drop auto: commits by subject afterwards.
    # Multiple words = AND across the message, not a literal phrase. One --grep per word
    # plus --all-match, so `why.sh clock skew` finds "the clock was 78 days slow" even
    # though that exact phrase appears nowhere.
    # NOTE: quoting does NOT force a phrase — the shell strips the quotes before we see
    # the words, so "used space only" is still AND. That is the useful default.
    # For a true phrase, use dots for the spaces:  ./setup/why.sh 'Used.Space.Only'
    # (a regex with literal spaces would be word-split into broken fragments here —
    # 'Used[ ]Space[ ]Only' becomes three patterns and matches nothing. Verified 08-02.)
    greps=()
    for w in $q; do greps+=(--grep="$w"); done
    [ ${#greps[@]} -gt 1 ] && greps+=(--all-match)
    for h in $(git --no-pager log --format='%H' --regexp-ignore-case "${greps[@]}" 2>/dev/null); do
      case "$(git --no-pager log -1 --format='%s' "$h")" in auto:*) continue;; esac
      _print_commit "$h"; found=1
    done
    if [ "$found" = 0 ]; then
      echo "  nothing matched. Try fewer words, or:  ./setup/why.sh -l 40"
    fi
    ;;
esac
