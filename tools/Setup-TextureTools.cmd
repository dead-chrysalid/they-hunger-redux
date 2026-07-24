@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-TextureTools.ps1" %*
exit /b %ERRORLEVEL%
