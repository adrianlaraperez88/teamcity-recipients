@echo off
setlocal enabledelayedexpansion

:: ==============================================================================
:: Reusable Connect Script
:: ==============================================================================
:: Authenticates and connects to a target network share.
::
:: Usage:
::   connect.bat [options]
::
:: Options:
::   --server <path>        Target server/UNC path (default: %DEPLOY_SERVER%)
::   --user <username>      Username (default: %user%)
::   --domain <domain>      Active Directory domain (default: %USER_DOMAIN% or %DOMAIN%)
::   --password <pwd>       Password (default: %password%)
::   --dry-run or /dryrun   Run in dry-run mode (does not execute actual commands)
:: ==============================================================================

:: Initialize variables (no percent expansion defaults to avoid syntax breaks if undefined)
set "SERVER="
set "USER_NAME="
set "AUTH_DOMAIN="
set "PASS_WORD="
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
if /i "%~1"=="--user" (
    set "USER_NAME=%~2"
    shift & shift
    goto parse_args
)
if /i "%~1"=="--domain" (
    set "AUTH_DOMAIN=%~2"
    shift & shift
    goto parse_args
)
if /i "%~1"=="--password" (
    set "PASS_WORD=%~2"
    shift & shift
    goto parse_args
)
shift
goto parse_args

:done_parsing

:: Fall back to environment variables if not passed as arguments
if "!SERVER!"=="" (
    if defined DEPLOY_SERVER (
        set "SERVER=!DEPLOY_SERVER!"
    ) else (
        echo [ERROR] Server path is not specified. Set DEPLOY_SERVER environment variable or use --server.
        exit /b 1
    )
)
if "!USER_NAME!"=="" (
    if defined user (
        set "USER_NAME=!user!"
    ) else (
        echo [ERROR] Username is not specified. Set user environment variable or use --user.
        exit /b 1
    )
)
if "!AUTH_DOMAIN!"=="" (
    if defined USER_DOMAIN (
        set "AUTH_DOMAIN=!USER_DOMAIN!"
    ) else if defined DOMAIN (
        set "AUTH_DOMAIN=!DOMAIN!"
    )
)
if "!PASS_WORD!"=="" (
    if defined password (
        set "PASS_WORD=!password!"
    ) else (
        echo [ERROR] Password is not specified. Set password environment variable or use --password.
        exit /b 1
    )
)

:: Format username: Prepend domain if specified and not already included in username
set "FULL_USER=!USER_NAME!"
if not "!AUTH_DOMAIN!"=="" (
    if "!USER_NAME:\=!"=="!USER_NAME!" (
        set "FULL_USER=!AUTH_DOMAIN!\!USER_NAME!"
    )
)

:: Execute connection
if "!DRY_RUN!"=="1" (
    echo [DRY-RUN] net use "!SERVER!" /user:"!FULL_USER!" [PASSWORD]
) else (
    echo Connecting to "!SERVER!" as "!FULL_USER!"...
    net use "!SERVER!" /user:"!FULL_USER!" "!PASS_WORD!"
    if errorlevel 1 (
        echo [ERROR] Failed to connect to server "!SERVER!".
        if defined TEAMCITY_VERSION echo ##teamcity[buildProblem description='Failed to connect to server !SERVER!']
        exit /b 1
    )
    echo [SUCCESS] Connected to "!SERVER!".
)

exit /b 0
