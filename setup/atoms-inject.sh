#!/usr/bin/env bash
# atoms-inject.sh — SessionStart fast-fact layer (PILOT).
#
# Injects memory/atoms.jsonl (rendered by atoms-inject.py) as additionalContext on every session
# so discrete, high-signal facts SURFACE without Paul having to prompt for them. This is the
# always-on counterpart to the load-memory skill's deep read: the skill reads whole .md files on
# request; this puts the distilled claims in front of the model every session, invoked or not.
#
# Pattern mirrors canon-memory-doctrine.sh: fire only when the repo is present, emit a single
# hookSpecificOutput JSON object, and ALWAYS exit 0 so a malformed atom never blocks a session.
#
# Interpreter detection is deliberate. jq is NOT reliably on the Git Bash PATH here, and the
# `python` on PATH is the 0-byte WindowsApps Store *stub* that environment.md warns about (it
# satisfies `command -v` but does nothing). So we try py -> python3 -> python and VERIFY each one
# actually RUNS (prints a marker) before trusting it — the same lesson setup-windows.ps1 encodes.
# All rendering/JSON-escaping lives in the .py (stdlib json); this wrapper only picks an engine.

REPO="${HOME}/Claude-Memory"
PY="${REPO}/setup/atoms-inject.py"

[ -d "${REPO}/.git" ] || exit 0
[ -f "${PY}" ]        || exit 0

# A real interpreter prints "1"; a Store-alias stub does not.
runs() { [ "$("$1" -c 'print(1)' 2>/dev/null)" = "1" ]; }

for cand in py python3 python; do
  if command -v "${cand}" >/dev/null 2>&1 && runs "${cand}"; then
    OUT="$("${cand}" "${PY}" 2>/dev/null)"
    [ -n "${OUT}" ] && printf '%s\n' "${OUT}"
    exit 0
  fi
done

exit 0   # no working interpreter → stay silent rather than break SessionStart
