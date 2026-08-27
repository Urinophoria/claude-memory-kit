#!/usr/bin/env bash
# tool-missing-guard.sh — PostToolUse ENFORCEMENT for STANDARDS §7 (never work around a missing tool).
#
# WHY THIS EXISTS: §7 has been canon for months and the rule STILL gets violated in nearly every
# session (Paul, angry, 2026-08-16: "this conversation needs to stop happening"). Stating a rule was
# not enough for §6 either — which is exactly why §6 is hook-enforced. §7 now gets the same treatment.
#
# A SessionStart reminder is scrolled past by the time it matters. THIS fires at the moment a command
# comes back reporting a missing tool/binary/module — the precise point where the wrong instinct
# (pivot to a workaround to keep moving fast) kicks in — and puts the rule in front of the model right
# then. It cannot rewrite the model's judgment, but it removes the "momentum / I forgot" failure mode.
#
# It scans the tool RESULT only (not the command text), so a command that merely MENTIONS a signature
# — e.g. a commit message about this very hook — does not trip it. Silent on every normal call.
# Non-fatal, always exit 0. Matches Bash|PowerShell. Travels to every machine via tracked
# .claude/settings.json (cross-machine, which is the whole point).

SIGS='command not found|not recognized as (the name of a cmdlet|an internal or external command)|ModuleNotFoundError|No module named|is not installed|Install .*(to enable|-utils)|no such tool'

INPUT="$(cat)"

# Cheap pre-filter: no signature anywhere → the common case, exit with zero extra cost.
printf '%s' "${INPUT}" | grep -qiE "${SIGS}" || exit 0

# Potential hit. Isolate the tool RESULT so a mere command-echo mention doesn't count. Python (py) is
# canon toolchain; if it is somehow unavailable, fall back to scanning everything (safe: catch more).
SCAN="$(printf '%s' "${INPUT}" | py -c "
import json,sys
def t(x):
    if x is None: return ''
    if isinstance(x,str): return x
    if isinstance(x,dict): return ' '.join(t(v) for v in x.values())
    if isinstance(x,list): return ' '.join(t(v) for v in x)
    return str(x)
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.stdout.write(t(d.get('tool_response')))
" 2>/dev/null)"
[ -z "${SCAN}" ] && SCAN="${INPUT}"

# Confirm the signature is in the RESULT, not just the command echo.
printf '%s' "${SCAN}" | grep -qiE "${SIGS}" || exit 0

MSG="STANDARDS section 7 -- TOOL MISSING. This is Paul's #1 HARD RULE and his single most aggressive standing pushback. A command just failed because a tool/binary/module is NOT available. DO NOT work around it, DO NOT substitute a lesser library, DO NOT pivot to keep moving. GET THE TOOL: install it (winget/pip/apt as appropriate) and, on a canon machine, add it to setup/ bootstrap. If it needs admin, hit Paul with an ELEVATION PROMPT (Start-Process -Verb RunAs) -- asking is the correct move, not a reason to downgrade. 'Installed but not on PATH' counts as missing: fix the PATH / use the full path / new shell. The workaround impulse is a SPEED impulse; Paul wants your BEST, not your fastest -- installing the right tool IS the job. His words: 'I won't have my partner driving nails with a damn screwdriver; my partner does not work hobbled.' If you genuinely cannot get it, STOP and tell Paul what you need -- never silently jury-rig."

ESCAPED="$(printf '%s' "${MSG}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "${ESCAPED}"

exit 0
