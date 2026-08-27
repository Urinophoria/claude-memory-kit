#!/usr/bin/env bash
# next-commit.sh — set the commit message the NEXT Stop-hook autosave will use.
#
# The Stop hook (setup/session-autosave.sh) commits + pushes any dirty tree at every turn/session
# end. Left to itself it invents a generic "auto:" message, and the "why" gets lost — which then
# tempts a second commit just to explain the first. Write your intended message here instead and
# the very next backstop commit uses it verbatim, then clears it. No separate clarifying commit.
#
# Usage:
#   bash setup/next-commit.sh "subject line"
#   bash setup/next-commit.sh "subject line" "" "body line 1" "body line 2"   # blank arg = blank line
#   some-generator | bash setup/next-commit.sh                                 # message from stdin
#
# Notes:
#   - Consumed by the NEXT autosave commit only, then deleted. Cleared automatically on any
#     clean-tree Stop, so it can never attach to an unrelated later change.
#   - Writes to .git/autosave-msg (never tracked, never pushed).
#   - Does NOT itself commit. It just stages the message for the hook.

REPO="${HOME}/Claude-Memory"
HINT="${REPO}/.git/autosave-msg"
[ -d "${REPO}/.git" ] || { echo "next-commit: no canon repo at ${REPO}" >&2; exit 1; }

if [ "$#" -gt 0 ]; then
  printf '%s\n' "$@" > "${HINT}"
else
  cat > "${HINT}"
fi

if [ ! -s "${HINT}" ]; then
  rm -f "${HINT}"
  echo "next-commit: empty message — hint cleared (autosave will use the generic tag)"
  exit 0
fi

echo "next-commit: the next autosave commit will use → $(head -1 "${HINT}")"
