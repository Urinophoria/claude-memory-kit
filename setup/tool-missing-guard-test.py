#!/usr/bin/env python3
"""tool-missing-guard-test.py — regression cases for setup/tool-missing-guard.sh (STANDARDS section 7).

Pipes hook payloads in the shapes Claude Code ACTUALLY sends through the guard and checks it fires on a real
missing tool -- a FAILED call (PostToolUseFailure: `error` = 'Exit code N' + the whole merged output) and an
exit-MASKED one (PostToolUse: the command's stderr is merged INTO stdout; tool_response.stderr only ever holds
the harness's 'Shell cwd was reset' note, and the PowerShell tool's is empty) -- echoes the event it was called
for (Claude Code rejects a mismatched hookEventName), gives the WindowsApps python stub its own message, and stays
SILENT when a command merely prints the words, whether that read succeeds or fails.
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
CWD_NOTE = "\nShell cwd was reset to C:\\Users\\me\\Claude-Memory"


def ok(stdout, tool="Bash"):
    """A successful (possibly exit-masked) call, as Claude Code sends it."""
    return {"hook_event_name": "PostToolUse", "tool_name": tool, "tool_input": {"command": "x"},
            "tool_response": {"stdout": stdout, "stderr": CWD_NOTE if tool == "Bash" else "",
                              "interrupted": False, "isImage": False}}


def failed(error, tool="Bash"):
    return {"hook_event_name": "PostToolUseFailure", "tool_name": tool, "tool_input": {"command": "x"}, "error": error}


def mid(line):
    return "before\n" + line + "\nafter\n"


DOC = ("SIGS='command not found|not recognized as (the name of a cmdlet|an internal or external command)'\n"
       "the guard fires when a command is not installed or 'command not found' appears; see STANDARDS 7.\n"
       "Evidence: the PowerShell tool printed \"The term 'zz' is not recognized as a name of a cmdlet\" mid-sentence.\n"
       "| The term 'x' is not recognized as a name of a cmdlet | (a markdown table row) |\n"
       "Note: jq is not installed on the kit runner yet; Install 7-Zip to enable the ISO listing.\n")
PS7_BLOCK = ("zz: \r\nLine |\r\n   2 |  zz --version\r\n     |  ~~\r\n     | The term 'zz' is not recognized as a name of a "
             "cmdlet, function, script file, or executable program.\r\n     | Check the spelling of the name.\r\nafter\r\n")
PS51_WRAP = ("zz : The term 'zz' is not recognized as the name of a \r\ncmdlet, function, script file, or operable program.\r\n"
             "At line:1 char:1\r\n+ zz\r\n+ ~~\r\n    + CategoryInfo          : ObjectNotFound: (zz:String) [], CommandNotFoundException\r\n")
STUB_TEXT = ("Python was not found; run without arguments to install from the Microsoft Store, or disable this shortcut "
             "from Settings > Apps > Advanced app settings > App execution aliases.")

# (label, payload, expected: "missing" | "stub" | None for silent)
CASES = [
    # --- FAILED calls: the common single-command missing tool ---
    ("bash exit 127", failed("Exit code 127\n/usr/bin/bash: line 1: jq: command not found"), "missing"),
    ("script path with drive + space", failed("Exit code 127\nC:/Users/me/sp ace/w.sh: line 2: zzprobe: command not found"), "missing"),
    ("dash /bin/sh", failed("Exit code 127\n/bin/sh: 1: jq: not found"), "missing"),
    ("exit 127, no 'not found' text", failed("Exit code 127\nenv: 'zzprobe': No such file or directory"), "missing"),
    ("cmd.exe exit 9009", failed("Exit code 9009\n'jq' is not recognized as an internal or external command,\r\noperable program or batch file."), "missing"),
    ("python module", failed("Exit code 1\nTraceback (most recent call last):\n  File \"<string>\", line 1\n"
                             "ModuleNotFoundError: No module named 'openpyxl'"), "missing"),
    ("pwsh 7 single line", failed("Exit code 1\nzzjq: The term 'zzjq' is not recognized as a name of a cmdlet, function, "
                                  "script file, or executable program.", "PowerShell"), "missing"),
    ("pwsh 5.1 wrapped mid-phrase", failed("Exit code 1\n" + PS51_WRAP, "PowerShell"), "missing"),
    ("pwsh module", failed("Exit code 1\nImport-Module: The specified module 'Az' was not loaded because no valid module "
                           "file was found in any module directory.", "PowerShell"), "missing"),
    ("error-prefixed loose phrase", failed("Exit code 1\nerror: 7-Zip is not installed"), "missing"),
    ("WSL not installed", failed("Exit code 1\nThe Windows Subsystem for Linux is not installed. You can install by running 'wsl.exe --install'."), "missing"),
    ("WindowsApps python stub", failed("Exit code 49\n" + STUB_TEXT), "stub"),
    # --- FAILED reads / non-tool failures: SILENT (the failure text carries the whole merged stdout) ---
    ("failed read of a doc", failed("Exit code 1\n" + DOC), None),
    ("failed test run quoting the phrase", failed("Exit code 1\nFAILED test_x - AssertionError: expected 'jq is not installed'"), None),
    (".NET 'not recognized as a valid'", failed("Exit code 1\nCannot convert value \"x\" to type \"System.DateTime\". Error: "
                                               "\"String 'x' was not recognized as a valid DateTime.\"", "PowerShell"), None),
    ("failure without a signature", failed("Exit code 1\nfatal: not a git repository"), None),
    # --- exit-MASKED calls (PostToolUse): the error arrives in STDOUT, mid-output ---
    ("masked bash", ok(mid("/usr/bin/bash: line 2: jq: command not found")), "missing"),
    ("masked bash, short form", ok(mid("bash: jq: command not found")), "missing"),
    ("masked dash", ok(mid("./build.sh: 3: jq: not found")), "missing"),
    ("masked zsh", ok(mid("zsh: command not found: jq")), "missing"),
    ("masked cmd.exe", ok(mid("'7z' is not recognized as an internal or external command,")), "missing"),
    ("masked pwsh 5.1", ok(PS51_WRAP + "after\r\n", "PowerShell"), "missing"),
    ("masked pwsh 7 'Line |' block", ok(PS7_BLOCK, "PowerShell"), "missing"),
    ("masked pwsh 7, ANSI colour", ok("\x1b[31;1mzz: \x1b[31;1mThe term 'zz' is not recognized as a name of a cmdlet, "
                                      "function, script file, or executable program.\x1b[0m\r\nafter\r\n", "PowerShell"), "missing"),
    ("masked pwsh module, ANSI", ok("\x1b[31;1mImport-Module: \x1b[31;1mThe specified module 'Az' was not loaded because "
                                    "no valid module file was found in any module directory.\x1b[0m\r\n", "PowerShell"), "missing"),
    ("masked py -m missing", ok("C:\\Users\\me\\AppData\\Local\\Programs\\Python\\Python313-arm64\\python.exe: No module named pytest\n"), "missing"),
    ("masked pytest E-line", ok(mid("E   ModuleNotFoundError: No module named 'requests'")), "missing"),
    ("masked python traceback", ok(mid("ModuleNotFoundError: No module named 'zz'")), "missing"),
    ("masked WSL", ok(mid("The Windows Subsystem for Linux is not installed.")), "missing"),
    ("masked stub", ok(mid(STUB_TEXT)), "stub"),
    # --- successful READS that merely contain the words: SILENT ---
    ("cat of a doc", ok(DOC), None),
    ("grep -n of the guard source", ok("18:SIGS='command not found|not recognized as (the name of a cmdlet|an "
                                       "internal or external command)|ModuleNotFoundError|No module named'\n"), None),
    ("grep -n of a doc quoting py -m", ok("FINDINGS.md:12: /usr/bin/python3: No module named pip\n"), None),
    ("findings report line", ok("FAILURE: ... returned 'Exit code 127 ... command not found' with NO hook.\n"), None),
    ("loose phrase on stdout, success", ok("error: 7-Zip is not installed\n"), None),
    ("plain success", ok("hello\n"), None),
]


def run(payload):
    p = subprocess.run([BASH, GUARD], input=json.dumps(payload), capture_output=True, text=True,
                       encoding="utf-8", timeout=30)
    if not p.stdout.strip():
        return None, None
    o = json.loads(p.stdout)["hookSpecificOutput"]
    kind = "stub" if "STORE ALIAS STUB" in o["additionalContext"] else "missing"
    return o["hookEventName"], kind


def main():
    passed = failed_n = 0
    for label, payload, want in CASES:
        try:
            event, kind = run(payload)
        except Exception as e:  # a crash or non-JSON output is a failure, not a pass
            event, kind = "ERROR", str(e)[:60]
        good = (kind is None) if want is None else (kind == want and event == payload["hook_event_name"])
        if good:
            passed += 1
        else:
            failed_n += 1
            print("  FAIL | %-34s expected %s, got %s" % (label, want or "silent", "%s/%s" % (event, kind) if kind else "silent"))
    print("\ntool-missing-guard-test: %d passed, %d failed" % (passed, failed_n))
    return 1 if failed_n else 0


if __name__ == "__main__":
    sys.exit(main())
