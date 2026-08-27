@echo off
REM ============================================================================
REM  Double-click to provision this machine for your Claude memory system.
REM  Runs bootstrap.ps1 with the execution-policy bypass baked in, so there are
REM  NO commands to remember. Run this from inside your cloned memory repo.
REM  (First read GETTING-STARTED.md — you clone your repo to %USERPROFILE%\Claude-Memory first.)
REM ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1"
echo.
echo ---------------------------------------------------------------------------
echo  If it finished, follow the "FINAL MANUAL STEPS" printed above.
echo ---------------------------------------------------------------------------
pause
