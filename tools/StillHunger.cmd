@echo off
setlocal
rem Codex can supply both "Path" and "PATH" in the same Windows environment
rem block. MSBuild treats those as duplicate dictionary keys and refuses to
rem launch CL.exe, so collapse them to one process-local variable up front.
set "StillHungerOriginalPath=%PATH%"
set "PATH="
set "Path="
set "Path=%StillHungerOriginalPath%"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0StillHunger.ps1" %*
set "StillHungerExitCode=%ERRORLEVEL%"
endlocal & exit /b %StillHungerExitCode%
