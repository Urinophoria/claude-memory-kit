#!/usr/bin/env bash
# atoms-inject.sh — the atoms fast-fact layer's hook wrapper (all args pass through to the .py).
#
#   atoms-inject.sh --hook     SessionStart: the BOOT tier (curated core + newest gists + index, < 10,000 chars)
#   atoms-inject.sh --prompt   UserPromptSubmit: RECALL the best-matching unseen atoms for each message
#   atoms-inject.sh            (no args) the boot payload, stdin untouched — what dr-check measures
#
# Claude Code caps each hook's additionalContext at 10,000 chars, so the layer is delivered in tiers
# rather than as one blob (see atoms-inject.py and memory/atoms.README.md). This is the always-on
# counterpart to the load-memory skill's deep read: the skill reads whole .md files on request; this
# puts the distilled claims in front of the model, invoked or not.
#
# Pattern mirrors canon-memory-doctrine.sh: fire only when the repo is present, emit a single
# hookSpecificOutput JSON object, and ALWAYS exit 0 so a malformed atom never blocks a session or a prompt.
#
# Interpreter detection is deliberate. jq is NOT reliably on the Git Bash PATH, and on Windows the
# `python` on PATH can be the 0-byte WindowsApps Store *stub* (it satisfies `command -v` but does
# nothing). So we try py -> python3 -> python and VERIFY each one actually RUNS (prints a marker)
# before trusting it. All rendering/JSON-escaping lives in the .py (stdlib json); this wrapper only
# picks an engine.

REPO="${HOME}/Claude-Memory"
PY="${REPO}/setup/atoms-inject.py"

[ -d "${REPO}/.git" ] || exit 0
[ -f "${PY}" ]        || exit 0

# A real interpreter prints "1"; a Store-alias stub does not.
runs() { [ "$("$1" -c 'print(1)' 2>/dev/null)" = "1" ]; }

for cand in py python3 python; do
  if command -v "${cand}" >/dev/null 2>&1 && runs "${cand}"; then
    OUT="$("${cand}" "${PY}" "$@" 2>/dev/null)"
    [ -n "${OUT}" ] && printf '%s\n' "${OUT}"
    exit 0
  fi
done

exit 0   # no working interpreter → stay silent rather than break SessionStart
