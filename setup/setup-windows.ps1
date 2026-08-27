# setup-windows.ps1 — install the core prerequisites + package the skills (Windows).
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
Write-Step "Checking Python"
$py = $null
foreach ($c in @("py","python3","python")) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    # skip the Microsoft Store 0-byte alias stub (satisfies Get-Command but does nothing)
    if ($cmd -and (& $c --version 2>$null)) { $py = $c; break }
}
if (-not $py) {
    Write-Note "Python not found — installing via winget…"
    winget install --id Python.Python.3.12 --silent --accept-package-agreements --accept-source-agreements
    Write-Note "Python installed. It may need a NEW shell to land on PATH — re-run this script if the next line fails."
    foreach ($c in @("py","python3","python")) { $cmd = Get-Command $c -ErrorAction SilentlyContinue; if ($cmd -and (& $c --version 2>$null)) { $py = $c; break } }
    if (-not $py) { Write-Fail "Python not on PATH yet — open a new PowerShell and re-run setup-windows.ps1" }
}
if ($py) { Write-OK "Python available ($py $(& $py --version 2>$null))" }

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
    Write-Host "SETUP INCOMPLETE — one or more steps failed (see the red FAIL lines above)." -ForegroundColor Red
    Write-Host "Fix the cause and re-run; do NOT trust this machine as fully provisioned." -ForegroundColor Red
    exit 1
}
Write-Host "Prerequisites installed and skills packaged. Upload each .zip from" -ForegroundColor Cyan
Write-Host "  $env:USERPROFILE\Downloads\cowork-skills\  via Customize > Skills > + > Upload a skill." -ForegroundColor White
Write-Host "You're all set!" -ForegroundColor Green
