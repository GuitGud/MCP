@echo off
setlocal
cd /d "%~dp0"
title MCP Startup Diagnostics

echo ============================================================
echo  MASTER CONTROL PROGRAM // STARTUP DIAGNOSTICS
echo ============================================================
echo.
echo Working folder: %CD%
echo.

if not exist "%~dp0MCP.ps1" (
    echo ERROR: MCP.ps1 is missing.
    echo Extract the complete repository before running MCP.
    goto :finish
)

if not exist "%~dp0src\MasterControlProgram.ps1" (
    echo ERROR: src\MasterControlProgram.ps1 is missing.
    echo Extract the complete repository before running MCP.
    goto :finish
)

where powershell.exe
if errorlevel 1 (
    echo ERROR: Windows PowerShell was not found.
    goto :finish
)

echo Starting MCP in diagnostic mode...
echo Keep this window open. Close MCP to return here.
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0MCP.ps1"
echo.
echo MCP exited with code %ERRORLEVEL%.
echo Startup log: %LOCALAPPDATA%\MasterControlProgram\mcp-startup.log

:finish
echo.
pause
endlocal

