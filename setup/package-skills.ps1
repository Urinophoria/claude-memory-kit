# package-skills.ps1 -- rebuild the upload-ready skill zips (memory-sweep T3e, 2026-08-26).
#
# WHY THIS EXISTS: editing skills/<name>/SKILL.md does NOT update the zips a machine uploads --
# those live in Downloads\cowork-skills\ and are only rebuilt when this packaging runs. So after
# any skill edit, run this, then re-upload via Customize > Skills, and update setup\skill-registry.md
# (re-upload a skill after editing it). setup-windows.ps1 runs this same logic on a fresh machine; this is the standalone
# you run on an EXISTING machine without re-doing the whole prereq install.
#
# THE ONE NON-OBVIOUS PART: the zip entries MUST use forward slashes. Compress-Archive and
# ZipFile.CreateFromDirectory both write BACKSLASH separators on Windows PowerShell 5.1, and Cowork's
# skill uploader rejects those as "path with invalid characters". So we add each file explicitly with a
# forward-slash entry name. Works on PS 5.1 AND PS 7.
#
# RUN:  pwsh -File setup\package-skills.ps1        (or right-click > Run with PowerShell)

$ErrorActionPreference = "Stop"
function Step($m){ Write-Host "`n==> $m" -ForegroundColor Cyan }
function OK($m){   Write-Host "    OK: $m" -ForegroundColor Green }
function Skip($m){ Write-Host "    skip: $m" -ForegroundColor DarkGray }

$claudeMemory = Join-Path $env:USERPROFILE "Claude-Memory"
$skillsRoot   = Join-Path $claudeMemory "skills"
$zipOut       = Join-Path $env:USERPROFILE "Downloads\cowork-skills"

if (-not (Test-Path $skillsRoot)) {
    Write-Host "    FAIL: skills folder not found at $skillsRoot -- is the repo cloned?" -ForegroundColor Red
    exit 1
}

# FRESHNESS GUARD -- never package from a clone that is BEHIND origin. This is how a *correct* re-upload
# can still serve a STALE skill: this script zips whatever the LOCAL clone holds, so running it on a box
# whose clone was behind origin ships the OLD SKILL.md. Fetch + refuse.
Step "Freshness check (clone must be current before packaging)"
$behind = $null
try { git -C $claudeMemory fetch -q origin 2>$null; $behind = (git -C $claudeMemory rev-list --count "HEAD..origin/main" 2>$null | Select-Object -First 1) } catch {}
if ($behind -and ([int]$behind) -gt 0) {
    Write-Host "    FAIL: clone is $behind commit(s) BEHIND origin/main -- packaging would ship a STALE skill." -ForegroundColor Red
    Write-Host "          Run:  git -C `"$claudeMemory`" pull --rebase   then re-run this." -ForegroundColor Red
    exit 1
} elseif ($behind -eq "0") {
    OK "clone current with origin/main (0 behind)"
} else {
    Write-Host "    WARN: could not verify clone freshness (git fetch failed / offline / not a repo). Make sure you pulled recently." -ForegroundColor Yellow
}

$excludeDirs  = @("__pycache__", ".git")
$excludeFiles = @("*.pyc", "*.pyo", "*.zip", "*.skill", ".sync-log", ".sync-queue", ".DS_Store", "Thumbs.db")

Step "Packaging skills from $skillsRoot -> $zipOut"
if (Test-Path $zipOut) { Remove-Item $zipOut -Recurse -Force }
New-Item -ItemType Directory -Path $zipOut | Out-Null

Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$built = @()
Get-ChildItem $skillsRoot -Directory | ForEach-Object {
    $skillDir  = $_
    $skillName = $_.Name
    if (-not (Test-Path (Join-Path $skillDir.FullName "SKILL.md"))) { Skip "$skillName has no SKILL.md"; return }

    # Stage a clean copy, prune junk
    $stage = Join-Path $env:TEMP "skillstage_$skillName"
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item "$($skillDir.FullName)\*" $stage -Recurse -Force
    foreach ($d in $excludeDirs)  { Get-ChildItem $stage -Recurse -Directory -Filter $d -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force }
    foreach ($f in $excludeFiles) { Get-ChildItem $stage -Recurse -File -Filter $f -ErrorAction SilentlyContinue | Remove-Item -Force }

    # AUTO-STAMP SKILL_VERSION = the date this skill's SKILL.md last changed, so the served copy
    # self-reports its age (the boot staleness self-check compares it to setup\skill-registry.md). Only
    # skills carrying a `SKILL_VERSION = <date>` line are touched. Write UTF-8 no-BOM (a BOM corrupts YAML).
    $skillMd = Join-Path $stage "SKILL.md"
    if (Test-Path $skillMd) {
        $verDate = (git -C $claudeMemory log -1 --format=%cd --date=short -- "skills/$skillName/SKILL.md" 2>$null | Select-Object -First 1)
        if ($verDate) {
            $orig = Get-Content $skillMd -Raw
            $stamped = [regex]::Replace($orig, '(SKILL_VERSION = )\d{4}-\d{2}-\d{2}', "`${1}$verDate")
            if ($stamped -ne $orig) { [System.IO.File]::WriteAllText($skillMd, $stamped); OK "stamped $skillName SKILL_VERSION = $verDate" }
        }
    }

    # Build with FORWARD-SLASH entry names (see header)
    $zipPath = Join-Path $zipOut "$skillName.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    $zipObj = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
    Get-ChildItem $stage -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($stage.Length + 1) -replace '\\', '/'
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipObj, $_.FullName, $rel) | Out-Null
    }
    $zipObj.Dispose()
    Remove-Item $stage -Recurse -Force
    OK "packaged $skillName -> $zipPath"
    $built += $skillName
}

Write-Host ""
Write-Host "Skills packaged: $($built -join ', ')" -ForegroundColor White
Write-Host "NEXT (per machine): Customize > Skills > + > Create skill > Upload a skill -- upload each .zip"
Write-Host "      from $zipOut, then record it in setup\skill-registry.md (re-upload after every edit)." -ForegroundColor Yellow
