# bootstrap.ps1 — provision this machine for your Claude memory system (Windows).
#
# ASSUMES you have already cloned YOUR memory repo to  %USERPROFILE%\Claude-Memory  and are running
# this from inside it. (See GETTING-STARTED.md for the full walkthrough.) It:
#   1. ensures git is installed
#   2. sets your git identity (from setup\config.ps1, if you filled it in)
#   3. clones any code projects listed in setup\project-repos.txt into Projects\
#   4. installs the thin ~/.claude/CLAUDE.md pointer from the template
#   5. runs setup-windows.ps1 (remaining prereqs + packages the skills into Downloads\cowork-skills)
#   6. prints the final manual steps (place secrets, upload skills)
#
# RUN:  right-click > Run with PowerShell   (or:  pwsh -File setup\bootstrap.ps1)

$ErrorActionPreference = "Stop"
function Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }
function OK($m){   Write-Host "    OK: $m" -ForegroundColor Green }
function Note($m){ Write-Host "    $m" }
# Fail() RECORDS the failure so the final banner can't lie about success.
$script:Failed = $false
function Fail($m){ Write-Host "    FAIL: $m" -ForegroundColor Red; $script:Failed = $true }

$Target   = Join-Path $env:USERPROFILE "Claude-Memory"
$RepoRoot = Split-Path -Parent $PSScriptRoot        # this script lives in <repo>\setup\

# --- config (optional) ----------------------------------------------------------
$cfg = Join-Path $PSScriptRoot "config.ps1"
$MemRepoUrl = ""; $GitUserName = ""; $GitUserEmail = ""
if (Test-Path $cfg) { . $cfg; OK "loaded setup\config.ps1" }
else { Note "no setup\config.ps1 (optional — copy from config.example.ps1 to set your repo URL/identity)" }

# 1. git -------------------------------------------------------------------------
Step "Checking git"
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Note "git not found — installing via winget…"
    winget install --id Git.Git --silent --accept-package-agreements --accept-source-agreements
    $gitCmd = "C:\Program Files\Git\cmd"; if (Test-Path $gitCmd) { $env:PATH = "$gitCmd;$env:PATH" }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Fail "git installed but not on PATH yet. Close this window, open a NEW PowerShell, and re-run."
    }
}
if (Get-Command git -ErrorAction SilentlyContinue) { OK "git available" }

# 2. git identity ----------------------------------------------------------------
if ($GitUserName)  { git config --global user.name  $GitUserName;  OK "git user.name set" }
if ($GitUserEmail) { git config --global user.email $GitUserEmail; OK "git user.email set" }
if (-not (git config --global user.email)) {
    Note "no global git user.email set — the auto-save commits need one. Set it (or fill config.ps1):"
    Note "  git config --global user.name  'Your Name'"
    Note "  git config --global user.email 'you@example.com'"
}

# 3. this working copy -----------------------------------------------------------
Step "Working copy"
if (Test-Path (Join-Path $Target ".git")) {
    OK "memory repo present at $Target"
} elseif ($RepoRoot -and (Test-Path (Join-Path $RepoRoot ".git")) -and ($RepoRoot -ne $Target)) {
    Note "You are running from $RepoRoot, not $Target."
    Note "Convention: your memory repo should live at $Target (the hooks hardcode that path)."
    Note "Move/clone it there, then re-run — or adjust the paths in .claude\settings.json."
} else {
    Fail "No git repo at $Target. Clone YOUR memory repo there first (see GETTING-STARTED.md), then re-run."
}

# 4. project repos (from the manifest) -------------------------------------------
Step "Cloning code projects (setup\project-repos.txt)"
$ProjDir = Join-Path $Target "Projects"; New-Item -ItemType Directory -Path $ProjDir -Force | Out-Null
$manifest = Join-Path $Target "setup\project-repos.txt"
if (Test-Path $manifest) {
    $urls = Get-Content $manifest | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
    if (-not $urls) { Note "no project repos listed yet (add clone URLs to project-repos.txt when you have some)" }
    foreach ($url in $urls) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($url); $dest = Join-Path $ProjDir $name
        if (Test-Path (Join-Path $dest ".git")) { Note "$name already present — pulling"; git -C $dest pull --ff-only }
        else { git clone $url $dest; if ($LASTEXITCODE -eq 0) { OK "cloned $name" } else { Fail "clone failed: $url" } }
    }
} else { Note "no project-repos.txt found — skipping" }

# 5. thin ~/.claude/CLAUDE.md pointer --------------------------------------------
Step "Installing ~/.claude/CLAUDE.md (thin pointer)"
$ClaudeDir = Join-Path $env:USERPROFILE ".claude"; New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
$claudeMd = Join-Path $ClaudeDir "CLAUDE.md"; $tpl = Join-Path $Target "setup\claude-md-template.md"
if (Test-Path $tpl) {
    if (Test-Path $claudeMd) { Copy-Item $claudeMd "$claudeMd.bak-bootstrap" -Force; Note "existing CLAUDE.md backed up" }
    Copy-Item $tpl $claudeMd -Force; OK "CLAUDE.md pointer installed (fill in the <…> placeholders once)"
} else { Fail "claude-md-template.md not found — skipping the CLAUDE.md pointer" }

# 6. full setup (prereqs + skill packaging) --------------------------------------
Step "Running setup-windows.ps1 (prereqs + skill packaging)"
$setup = Join-Path $Target "setup\setup-windows.ps1"
if (Test-Path $setup) {
    & $setup
    if ($LASTEXITCODE -ne 0) { Fail "setup-windows.ps1 exited $LASTEXITCODE — prereqs/skill packaging INCOMPLETE" }
} else { Fail "setup-windows.ps1 not found at $setup" }

# 7. summary ---------------------------------------------------------------------
if ($script:Failed) {
    Write-Host ""; Step "Bootstrap FAILED — environment is INCOMPLETE"
    Write-Host "  Fix the red FAIL line(s) above and re-run. Do NOT trust this machine as provisioned." -ForegroundColor Red
    exit 1
}
Step "Bootstrap complete!"
Write-Host ""
Write-Host "FINAL MANUAL STEPS (per machine, one time):" -ForegroundColor Yellow
Write-Host "  1. In Claude, set the work folder to:  $Target"
Write-Host "  2. Place your SECRETS.local.md into  $Target\memory\  (from YOUR secure channel — a vault,"
Write-Host "     a USB, a password manager). It is git-ignored and never leaves your machine via git."
Write-Host "  3. Customize > Skills > + > Create skill > Upload a skill: upload each .zip from"
Write-Host "     $env:USERPROFILE\Downloads\cowork-skills\"
Write-Host "  4. Run  /load-memory  to boot your context."
Write-Host ""
Write-Host "From now on, sync this machine with:  git -C `"$Target`" pull" -ForegroundColor Green
