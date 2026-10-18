#!/usr/bin/env bash
# tool-missing-guard.sh — PostToolUse + PostToolUseFailure ENFORCEMENT for STANDARDS §7 (never work around a
# missing tool).
#
# WHY THIS EXISTS: a rule that is only stated gets violated anyway -- the workaround impulse wins in the
# moment. §6 is hook-enforced for the same reason, and §7 gets the same treatment.
#
# A SessionStart reminder is scrolled past by the time it matters. THIS fires at the moment a command
# comes back reporting a missing tool/binary/module — the precise point where the wrong instinct
# (pivot to a workaround to keep moving fast) kicks in — and puts the rule in front of the model right
# then. It cannot rewrite the model's judgment, but it removes the "momentum / I forgot" failure mode.
#
# TWO EVENTS: a missing tool makes the command FAIL (exit 127 / 1), and Claude Code
# delivers a failed call to PostToolUseFailure (payload field `error`), never to PostToolUse -- so while this
# hook was registered on PostToolUse alone it fired only when a pipe or `; echo` masked the exit code. It is
# now registered on both, and echoes the event it was called for (Claude Code rejects a mismatched name).
#
# TWO TIERS OF SIGNATURE: it once fired on every READ whose output merely contained the words -- cat'ing
# this file, grepping STANDARDS, a findings report -- which trains the model to scroll past it. So:
#   STRICT  the exact line shapes real errors print (line-anchored): bash/sh/zsh 'X: command not found', pwsh 7
#           AND 5.1 'The term 'X' is not recognized as a/the name of a cmdlet' (7's wording was missing),
#           cmd.exe ''X' is not recognized as an internal or external command', 'ModuleNotFoundError: No module
#           named', pwsh 'module ... was not loaded because no valid module file was found'. Counted in stdout,
#           stderr and the failure text.
#   LOOSE   the old free-text phrases ('command not found', 'is not installed', 'Install ... to enable', ...).
#           Counted only in stderr and the failure text -- where a real error lands, and a document never does.
# It scans the tool RESULT only (never the command text). Silent on every normal call. Non-fatal, always
# exit 0. Matches Bash|PowerShell. Travels to every machine via tracked .claude/settings.json.

ANY='command not found|not recognized as|ModuleNotFoundError|No module named|is not installed|Install .*(to enable|-utils)|no such tool|no valid module file was found|: not found'

INPUT="$(cat)"

# Cheap pre-filter: no signature anywhere → the common case, exit with zero extra cost.
printf '%s' "${INPUT}" | grep -qiE "${ANY}" || exit 0

PY=""
for c in py python3 python; do
  if command -v "${c}" >/dev/null 2>&1 && "${c}" -c "import sys" >/dev/null 2>&1; then PY="${c}"; break; fi
done

# Potential hit: decide on the RESULT, by channel. Prints the hook event name on a hit, nothing otherwise.
# (A quoted heredoc, so bash never touches the regexes; the payload itself arrives on stdin.)
GUARD_PY="$(cat <<'PYEOF'
import json, re, sys
STRICT = re.compile("|".join([
    r"^[\w/.~-]+(?:: line \d+)?: [^\s:]+: command not found\s*$",
    r"^sh: \d+: [^\s:]+: not found\s*$",
    r"^zsh: command not found: \S+",
    r"^(?:[^\s:]+ ?: )?The term '[^']+' is not recognized as (?:a|the) name of a cmdlet",
    r"^'[^']+' is not recognized as an internal or external command",
    r"^\s*(?:ModuleNotFoundError|ImportError): No module named",
    r"^(?:[^\s:]+ ?: )?The specified module '[^']+' was not loaded because no valid module file was found",
]), re.M)
LOOSE = re.compile(r"command not found|not recognized as|ModuleNotFoundError|No module named|is not installed"
                   r"|Install .*(?:to enable|-utils)|no such tool|no valid module file was found", re.I)


def t(x):
    if x is None:
        return ""
    if isinstance(x, str):
        return x
    if isinstance(x, dict):
        return " ".join(t(v) for v in x.values())
    if isinstance(x, list):
        return " ".join(t(v) for v in x)
    return str(x)


try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(2)
ev = d.get("hook_event_name") or "PostToolUse"
if ev == "PostToolUseFailure":
    out = err = t(d.get("error"))
else:
    r = d.get("tool_response")
    if isinstance(r, dict) and ("stdout" in r or "stderr" in r):
        out, err = t(r.get("stdout")) + "\n" + t(r.get("stderr")), t(r.get("stderr"))
    else:
        out, err = t(r), ""
if STRICT.search(out) or LOOSE.search(err):
    print(ev)
PYEOF
)"
RC=0
EVENT="$(printf '%s' "${INPUT}" | "${PY:-py}" -c "${GUARD_PY}" 2>/dev/null)" || RC=$?
# No usable python, or the payload was not JSON: the old behaviour -- scan everything, catch more.
if [ "${RC}" -ne 0 ] && [ -z "${EVENT}" ]; then
  EVENT="$(printf '%s' "${INPUT}" | grep -o '"hook_event_name"[[:space:]]*:[[:space:]]*"[A-Za-z]*"' | head -1 | sed 's/.*"\([A-Za-z]*\)"$/\1/')"
  EVENT="${EVENT:-PostToolUse}"
fi
[ -n "${EVENT}" ] || exit 0

MSG="STANDARDS section 7 -- TOOL MISSING. This is the user's #1 hard rule. A command just failed because a tool/binary/module is NOT available. DO NOT work around it, DO NOT substitute a lesser library, DO NOT pivot to keep moving. GET THE TOOL: install it (winget/pip/apt/brew as appropriate) and, on a canon machine, add it to setup/ bootstrap. If it needs admin, ASK THE USER for an elevation prompt -- asking is the correct move, not a reason to downgrade. 'Installed but not on PATH' counts as missing: fix the PATH / use the full path / new shell. (First confirm it is really absent: a 'not found' can be a stub's lie.) The workaround impulse is a SPEED impulse; the user wants your BEST, not your fastest -- installing the right tool IS the job. If you genuinely cannot get it, STOP and tell the user what you need -- never silently jury-rig."

ESCAPED="$(printf '%s' "${MSG}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "${EVENT}" "${ESCAPED}"

exit 0
