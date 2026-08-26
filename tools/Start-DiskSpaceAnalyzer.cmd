@echo off
rem Double-click launcher for the Disk Space Analyzer window.
rem STA is required for Windows Forms; -NoProfile keeps a user's profile out of the way.
setlocal
set "SCRIPT=%~dp0Start-DiskSpaceAnalyzer.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%" %*
if errorlevel 1 pause
endlocal
