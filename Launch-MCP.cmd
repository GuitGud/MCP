@echo off
setlocal
cd /d "%~dp0"

if not exist "%~dp0MCP.ps1" goto :not_extracted
if not exist "%~dp0src\MasterControlProgram.ps1" goto :not_extracted

where powershell.exe >nul 2>&1
if errorlevel 1 goto :no_powershell

start "" powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0MCP.ps1" >nul 2>&1
exit /b 0

:not_extracted
echo.
echo  MCP could not find all of its application files.
echo.
echo  If you opened this from a ZIP, right-click the ZIP, choose
echo  "Extract All", then run Launch-MCP.cmd from the extracted folder.
echo.
pause
exit /b 2

:no_powershell
echo.
echo  MCP requires Windows PowerShell 5.1, but powershell.exe was not found.
echo  Run Diagnose-MCP.cmd for more information.
echo.
pause
exit /b 3

endlocal
