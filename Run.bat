@echo off
REM Bluebeam Preferences Updater - Launcher
REM This batch file launches the PowerShell script with appropriate execution policy

title Bluebeam Preferences Updater

REM Get the directory where this batch file is located
set "SCRIPT_DIR=%~dp0"

REM Run PowerShell script with bypass execution policy
REM Extra arguments are forwarded (e.g. "Run.bat -All" for silent mode)
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%UpdateBluebeamPreferences.ps1" %*

REM Keep window open if there was an error
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo An error occurred. Please review the messages above.
    pause
)


