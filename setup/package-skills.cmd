@echo off
REM ============================================================================
REM  Double-click to REBUILD the skill zips after editing a skill.
REM  Runs package-skills.ps1 (next to this file) with the execution-policy bypass,
REM  so there are NO commands to remember. Writes upload-ready zips to
REM  %USERPROFILE%\Downloads\cowork-skills\  (forward-slash entries -- the only kind
REM  Cowork accepts; a hand-made Windows zip is rejected).
REM  Needs the repo cloned at %USERPROFILE%\Claude-Memory first (run bootstrap.cmd).
REM ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0package-skills.ps1"
echo.
echo ---------------------------------------------------------------------------
echo  Next: Customize ^> Skills ^> + ^> Upload a skill -- upload each .zip from
echo  Downloads\cowork-skills\ , then record it in setup\skill-registry.md.
echo ---------------------------------------------------------------------------
pause
