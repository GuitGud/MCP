@echo off
setlocal
cd /d "%~dp0"
start "Master Control Program" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0MCP.ps1"
endlocal

