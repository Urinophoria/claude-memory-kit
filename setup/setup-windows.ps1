# setup-windows.ps1 - install the core prerequisites + package the skills (Windows).
#
# Called by bootstrap.ps1, but safe to run on its own to re-package skills after editing one.
# Keeps the prereqs LEAN on purpose: git (bootstrap handles it) + Python (the atoms / render / doctor
# tools are Python). Add your own tools here as your skills grow.
#
# RUN:  pwsh -File setup\setup-windows.ps1

$ErrorActionPreference = "Stop"
function Write-Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK($m)  { Write-Host "    OK: $m" -ForegroundColor Green }
function Write-Note($m){ Write-Host "    $m" }
$script:Failed = $false
function Write-Fail($m){ Write-Host "    FAIL: $m" -ForegroundColor Red; $script:Failed = $true }

# --- PART 1: Python (needed by atoms-*.py, render-session.py, dr-check's helpers) ----------------
# Get-RealPython must survive a FRESH box, where `python` / `python3` resolve to the 0-byte Microsoft
# Store alias STUBS under ...\WindowsApps\. A stub satisfies Get-Command, writes "Python was not found"
# to stderr and exits non-zero -- and under $ErrorActionPreference = "Stop" in Windows PowerShell 5.1, a
# native command's stderr THROWS a terminating NativeCommandError, even when redirected to $null. So:
# skip WindowsApps paths outright, probe under a local SilentlyContinue, try `py` (the launcher, never a
# stub) first, and after a winget install look on disk (this process's PATH is a stale launch-time
# snapshot; a new Python is not on it yet).
function Get-RealPython {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        foreach ($c in @("py","python","python3")) {
            $cmd = Get-Command $c -ErrorAction SilentlyContinue
            if (-not $cmd -or $cmd.Source -like "*\WindowsApps\*") { continue }
            $v = & $cmd.Source --version 2>&1
            if ($LASTEXITCODE -eq 0 -and "$v" -match "Python 3\.\d+") { return $cmd.Source }
        }
        $onDisk = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" -ErrorAction SilentlyContinue |
                  Where-Object { $_.Length -gt 0 } | Sort-Object FullName -Descending | Select-Object -First 1
        if ($onDisk) { return $onDisk.FullName }
        return $null
    } finally { $ErrorActionPreference = $saved }
}

Write-Step "Checking Python"
$pyExe = Get-RealPython
if (-not $pyExe) {
    Write-Note "Python not found - installing via winget (user scope; Store stubs don't count)..."
    winget install --id Python.Python.3.13 --exact --scope user --silent --accept-package-agreements --accept-source-agreements
    $pyExe = Get-RealPython
}
if ($pyExe) {
    $saved = $ErrorActionPreference; $ErrorActionPreference = "SilentlyContinue"
    $pyVer = & $pyExe --version 2>&1
    $ErrorActionPreference = $saved
    Write-OK "Python available ($pyExe, $pyVer)"
} else {
    Write-Fail "winget did not produce a working Python - install Python 3 manually (python.org, user install), then re-run."
}

# --- PART 2: package the skills into upload-ready zips -------------------------------------------
Write-Step "Packaging skills"
$pkg = Join-Path $PSScriptRoot "package-skills.ps1"
if (Test-Path $pkg) {
    & $pkg
    if ($LASTEXITCODE -ne 0) { Write-Fail "package-skills.ps1 exited $LASTEXITCODE" }
} else { Write-Fail "package-skills.ps1 not found next to this script" }

# --- summary ------------------------------------------------------------------------------------
Write-Host ""
if ($script:Failed) {
    Write-Host "SETUP INCOMPLETE - one or more steps failed (see the red FAIL lines above)." -ForegroundColor Red
    Write-Host "Fix the cause and re-run; do NOT trust this machine as fully provisioned." -ForegroundColor Red
    exit 1
}
Write-Host "Prerequisites installed and skills packaged. Upload each .zip from" -ForegroundColor Cyan
Write-Host "  $env:USERPROFILE\Downloads\cowork-skills\  via Customize > Skills > + > Upload a skill." -ForegroundColor White
Write-Host "You're all set!" -ForegroundColor Green
# Explicit success exit: without it the LAST native command's $LASTEXITCODE (a benign non-zero from some
# installer) leaks to bootstrap.ps1, which would brand a fully provisioned machine "Bootstrap FAILED".
exit 0
