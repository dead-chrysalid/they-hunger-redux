@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0StillHunger.ps1" %*
exit /b %ERRORLEVEL%
