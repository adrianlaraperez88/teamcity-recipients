@echo off
setlocal enabledelayedexpansion

:: ==============================================================================
:: Reusable Disconnect Script
:: ==============================================================================
:: Disconnects from the target network share.
::
:: Usage:
::   disconnect.bat [options]
::
:: Options:
::   --server <path>        Target server/UNC path (default: %DEPLOY_SERVER%)
::   --dry-run or /dryrun   Run in dry-run mode (does not execute actual commands)
:: ==============================================================================

:: Initialize variables (no percent expansion defaults to avoid syntax breaks if undefined)
set "SERVER="
set "DRY_RUN=0"

:: Parse arguments
:parse_args
if "%~1"==" " goto parse_args
if "%~1"=="" goto done_parsing

if /i "%~1"=="--dry-run" (
    set "DRY_RUN=1"
    shift
    goto parse_args
)
if /i "%~1"=="/dryrun" (
    set "DRY_RUN=1"
    shift
    goto parse_args
)
if /i "%~1"=="--server" (
    set "SERVER=%~2"
    shift & shift
    goto parse_args
)
shift
goto parse_args

:done_parsing

:: Fall back to environment variable if not passed as argument
if "!SERVER!"=="" (
    if defined DEPLOY_SERVER (
        set "SERVER=!DEPLOY_SERVER!"
    ) else (
        echo [ERROR] Server path is not specified. Set DEPLOY_SERVER environment variable or use --server.
        exit /b 1
    )
)

:: Execute disconnection
if "!DRY_RUN!"=="1" (
    echo [DRY-RUN] net use "!SERVER!" /delete
) else (
    echo Disconnecting from "!SERVER!"...
    net use "!SERVER!" /delete
    if errorlevel 1 (
        echo [WARNING] Failed to disconnect from "!SERVER!".
        if defined TEAMCITY_VERSION echo ##teamcity[message text='Failed to disconnect from !SERVER!' status='WARNING']
    ) else (
        echo [SUCCESS] Disconnected from "!SERVER!".
    )
)

exit /b 0
