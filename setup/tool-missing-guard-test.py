#!/usr/bin/env python3
"""tool-missing-guard-test.py — regression cases for setup/tool-missing-guard.sh (STANDARDS section 7).

Pipes realistic Claude Code hook payloads through the guard and checks it FIRES on a real missing tool --
on a FAILED call (PostToolUseFailure, field `error`) as well as an exit-masked one (PostToolUse) -- echoes
the event it was called for (Claude Code rejects a mismatched hookEventName), and stays SILENT when a
successful command merely prints the words (cat'ing a doc, grepping the guard's own source).
Run:  py -3 setup/tool-missing-guard-test.py     Exit 0 = all pass, 1 = a case regressed.
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
GUARD = os.path.join(HERE, "tool-missing-guard.sh")
BASH = shutil.which("bash") or "bash"


def ok(stdout="", stderr=""):
    return {"hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_input": {"command": "x"},
            "tool_response": {"stdout": stdout, "stderr": stderr, "interrupted": False}}


def failed(error):
    return {"hook_event_name": "PostToolUseFailure", "tool_name": "Bash", "tool_input": {"command": "x"},
            "error": error}


DOC = ("SIGS='command not found|not recognized as (the name of a cmdlet|an internal or external command)'\n"
       "the guard fires when a command is not installed or 'command not found' appears; see STANDARDS 7.\n"
       "Evidence: the PowerShell tool printed \"The term 'zz' is not recognized as a name of a cmdlet\" mid-sentence.")

# (label, payload, expected event or None for silent)
CASES = [
    # --- a FAILED call: the common single-command missing tool (was never seen before PostToolUseFailure) ---
    ("bash exit 127", failed("Exit code 127\n/usr/bin/bash: line 1: jq: command not found"), "PostToolUseFailure"),
    ("script error", failed("Exit code 127\nsetup/foo.sh: line 12: 7z: command not found"), "PostToolUseFailure"),
    ("python module", failed("Exit code 1\nTraceback (most recent call last):\n  File \"<string>\", line 1\n"
                             "ModuleNotFoundError: No module named 'openpyxl'"), "PostToolUseFailure"),
    ("pwsh 7 cmdlet", failed("zzjq: The term 'zzjq' is not recognized as a name of a cmdlet, function, script "
                             "file, or executable program."), "PostToolUseFailure"),
    ("pwsh 5.1 cmdlet", failed("zz : The term 'zz' is not recognized as the name of a cmdlet, function, script "
                               "file, or operable program."), "PostToolUseFailure"),
    ("cmd.exe", failed("'jq' is not recognized as an internal or external command,\noperable program or batch file."),
     "PostToolUseFailure"),
    ("pwsh module", failed("Import-Module: The specified module 'Az' was not loaded because no valid module file "
                           "was found in any module directory."), "PostToolUseFailure"),
    ("loose phrase in failure text", failed("Exit code 1\nerror: 7-Zip is not installed"), "PostToolUseFailure"),
    # --- an exit-MASKED missing tool (a pipe / '; echo'): PostToolUse, error on stderr or as a strict line ---
    ("masked, stderr", ok("done\n", "/usr/bin/bash: line 1: jq: command not found\n"), "PostToolUse"),
    ("masked, 2>&1 strict line", ok("ModuleNotFoundError: No module named 'zz'\nafter\n"), "PostToolUse"),
    ("masked pwsh 7 caught", ok("The term 'zzjq' is not recognized as a name of a cmdlet, function, script file, "
                                "or executable program.\nafter\n"), "PostToolUse"),
    # --- a successful READ that merely contains the words: SILENT (it fired on these all through 10-17) ---
    ("cat of a doc", ok(DOC), None),
    ("grep of the guard source", ok("18:SIGS='command not found|not recognized as (the name of a cmdlet|an "
                                    "internal or external command)|ModuleNotFoundError|No module named'\n"), None),
    ("prose 'is not installed' on stdout", ok("Note: jq is not installed on the kit runner yet.\n"), None),
    ("findings report line", ok("FAILURE: ... returned 'Exit code 127 ... command not found' with NO hook.\n"), None),
    ("plain success", ok("hello\n"), None),
    ("failure without a signature", failed("Exit code 1\nfatal: not a git repository"), None),
]


def run(payload):
    p = subprocess.run([BASH, GUARD], input=json.dumps(payload), capture_output=True, text=True,
                       encoding="utf-8", timeout=30)
    if not p.stdout.strip():
        return None
    return json.loads(p.stdout)["hookSpecificOutput"]["hookEventName"]


def main():
    passed = failed_n = 0
    for label, payload, want in CASES:
        try:
            got = run(payload)
        except Exception as e:  # a crash or non-JSON output is a failure, not a pass
            got = "ERROR %s" % e
        if got == want:
            passed += 1
        else:
            failed_n += 1
            print("  FAIL | %-32s expected %s, got %s" % (label, want or "silent", got or "silent"))
    print("\ntool-missing-guard-test: %d passed, %d failed" % (passed, failed_n))
    return 1 if failed_n else 0


if __name__ == "__main__":
    sys.exit(main())
