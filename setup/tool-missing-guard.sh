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
# WHAT COUNTS WHERE. Claude Code MERGES a command's stderr into stdout,
# and a failed call's `error` is 'Exit code N' + that whole merged output -- so neither channel is free of the
# document text a read prints. A naive scan fires on every such read (cat'ing this file, grepping docs).
#   STRICT  line-anchored shapes only real errors print: bash/sh/dash/zsh 'command not found' / 'X: N: Y: not
#           found' (any script path, drive letters and spaces included), pwsh 7 + 5.1 'The term 'X' is not
#           recognized as a/the name of a cmdlet' (single-line, the multi-line 'Line |' gutter, 5.1's mid-phrase
#           wrap), cmd.exe, 'ModuleNotFoundError' (pytest's 'E   ' too), '<path>python.exe: No module named X',
#           pwsh 'no valid module file was found', WSL 'is not installed'. ANSI colour codes are stripped
#           first. Counted on every call, success or failure.
#   FAILED  also: an 'Exit code 127' / '9009' header (shell / cmd.exe 'not found'), and the free-text phrases
#           ('is not installed', 'Install ... to enable', 'no such tool', ...) on lines that START like an error
#           ('error:', 'fatal:', 'E:'). Free-text phrases are never counted on a successful call.
#   STUB    the WindowsApps 'Python was not found' alias gets its own message: Python is usually installed, and
#           the fix is `py -3`, not an install.
# It scans the tool RESULT only (never the command text). Silent on every normal call. Non-fatal, always
# exit 0. Matches Bash|PowerShell. Travels to every machine via tracked .claude/settings.json.
# Regression cases: setup/tool-missing-guard-test.py.

ANY='command not found|not recognized as|ModuleNotFoundError|No module named|is not installed|Install .*(to enable|-utils)|no such tool|no valid module file was found|: not found|Python was not found|Exit code (127|9009)'

INPUT="$(cat)"

# Cheap pre-filter: no signature anywhere → the common case, exit with zero extra cost.
printf '%s' "${INPUT}" | grep -qiE "${ANY}" || exit 0

PY=""
for c in py python3 python; do
  if command -v "${c}" >/dev/null 2>&1 && "${c}" -c "import sys" >/dev/null 2>&1; then PY="${c}"; break; fi
done

# Potential hit: decide on the RESULT. Prints "<event> <kind>" (kind = missing | stub) on a hit, nothing otherwise.
# (A quoted heredoc, so bash never touches the regexes; the payload itself arrives on stdin.)
GUARD_PY="$(cat <<'PYEOF'
import json, re, sys
PS_PREFIX = r"(?:[^\s:]+ ?: | {2,}\| )?"          # 'zz: ' / 'zz : ' (5.1) / the multi-line 'Line |' gutter
STRICT = re.compile("|".join([
    r"^(?:[A-Za-z]:)?[^:\r\n]*?: line \d+: [^\s:]+: command not found\s*$",
    r"^[\w/.~-]+: [^\s:]+: command not found\s*$",
    r"^(?:[A-Za-z]:)?[^:\s]+: \d+: [^\s:]+: not found\s*$",
    r"^zsh: command not found: \S+",
    r"^" + PS_PREFIX + r"The term '[^']+' is not recognized as\s+(?:a|the)\s+name\s+of\s+a\s+cmdlet",
    r"^'[^']+' is not recognized as an internal or external command",
    r"^\s*(?:E\s+)?(?:ModuleNotFoundError|ImportError): No module named",
    r"^(?i:(?:[A-Za-z]:)?[^:\r\n]*?python[\w.]*(?:\.exe)?): No module named [\w.]+\s*$",
    r"^" + PS_PREFIX + r"The specified module '[^']+' was not loaded because\s+no\s+valid\s+module\s+file\s+was\s+found",
    r"^The Windows Subsystem for Linux is not installed",
]), re.M)
STUB = re.compile(r"^(?:[^\s:]+ ?: )?Python was not found; run without arguments to install from the Microsoft Store", re.M)
EXIT_NOT_FOUND = re.compile(r"\AExit code (?:127|9009)\b")
LOOSE_ERRLINE = re.compile(r"(?im)^\s*(?:error|fatal|e|err)\s*:.*(?:command not found|is not installed|Install .*(?:to enable|-utils)"
                           r"|no such tool|No module named|not recognized as\s+(?:(?:a|the)\s+name\s+of\s+a\s+cmdlet|an\s+internal\s+or\s+external))")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


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
    text = ANSI.sub("", t(d.get("error")).replace("\r\n", "\n"))
    hit = STRICT.search(text) or EXIT_NOT_FOUND.search(text) or LOOSE_ERRLINE.search(text)
else:
    r = d.get("tool_response")
    if isinstance(r, dict) and ("stdout" in r or "stderr" in r):
        text = t(r.get("stdout")) + "\n" + t(r.get("stderr"))
    else:
        text = t(r)
    text = ANSI.sub("", text.replace("\r\n", "\n"))
    hit = STRICT.search(text)
if hit:
    print(ev, "missing")
elif STUB.search(text):
    print(ev, "stub")
PYEOF
)"
RC=0
OUT="$(printf '%s' "${INPUT}" | "${PY:-py}" -c "${GUARD_PY}" 2>/dev/null)" || RC=$?
# No usable python, or the payload was not JSON: the old behaviour -- scan everything, catch more.
if [ "${RC}" -ne 0 ] && [ -z "${OUT}" ]; then
  EV="$(printf '%s' "${INPUT}" | grep -o '"hook_event_name"[[:space:]]*:[[:space:]]*"[A-Za-z]*"' | head -1 | sed 's/.*"\([A-Za-z]*\)"$/\1/')"
  OUT="${EV:-PostToolUse} missing"
fi
[ -n "${OUT}" ] || exit 0
EVENT="${OUT%% *}"
KIND="${OUT##* }"

if [ "${KIND}" = "stub" ]; then
  MSG="STANDARDS section 7 -- 'Python was not found' is the WindowsApps STORE ALIAS STUB answering, not proof Python is missing: Python is often installed and reachable as \`py -3\` (or python3). Re-run with \`py -3\` / \`python3\` (never the bare stub). Only if \`py -3\` ALSO fails is Python truly missing -- then section 7 applies in full: GET THE TOOL (install it / add it to setup/ bootstrap; ask the user for an elevation prompt if it needs admin), never a workaround or a lesser library."
else
  MSG="STANDARDS section 7 -- TOOL MISSING. This is the user's #1 hard rule. A command just failed because a tool/binary/module is NOT available. DO NOT work around it, DO NOT substitute a lesser library, DO NOT pivot to keep moving. GET THE TOOL: install it (winget/pip/apt/brew as appropriate) and, on a canon machine, add it to setup/ bootstrap. If it needs admin, ASK THE USER for an elevation prompt -- asking is the correct move, not a reason to downgrade. 'Installed but not on PATH' counts as missing: fix the PATH / use the full path / new shell. (First confirm it is really absent: a 'not found' can be a stub's lie.) The workaround impulse is a SPEED impulse; the user wants your BEST, not your fastest -- installing the right tool IS the job. If you genuinely cannot get it, STOP and tell the user what you need -- never silently jury-rig."
fi

ESCAPED="$(printf '%s' "${MSG}" | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":"%s"}}\n' "${EVENT}" "${ESCAPED}"

exit 0
