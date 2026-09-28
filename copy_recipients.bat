@echo off
setlocal enabledelayedexpansion
set "SCRIPT_NAME=%~nx0"

:: ==============================================================================
:: Configurable Recipients Copy Script
:: ==============================================================================
:: This script copies files for one or more recipients to a remote network server.
:: It automatically handles server authentication, directory cleanup, copying,
:: and final disconnection.
::
:: Usage:
::   copy_recipients.bat [options] [recipient1 [recipient2 ...]]
::
:: Options:
::   --server <path>        Target server/UNC path (default: %DEPLOY_SERVER%)
::   --user <username>      Username (default: %user%)
::   --domain <domain>      Active Directory domain (default: %USER_DOMAIN% or %DOMAIN%)
::   --password <pwd>       Password (default: %password%)
::   --recipients "list"    Space-separated list of recipients
::   --dry-run or /dryrun   Run in dry-run mode (does not execute actual commands)
:: ==============================================================================

:: Initialize variables (no percent expansion defaults to avoid syntax breaks if undefined)
set "SERVER="
set "USER_NAME="
set "AUTH_DOMAIN="
set "PASS_WORD="
set "RECIPIENTS="
set "DRY_RUN=0"

:: Parse command-line arguments
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
if /i "%~1"=="--recipients" (
    set "RECIPIENTS=%~2"
    shift & shift
    goto parse_args
)

:: Treat other positional arguments as recipients
if "!RECIPIENTS!"=="" (
    set "RECIPIENTS=%~1"
) else (
    set "RECIPIENTS=!RECIPIENTS! %~1"
)
shift
goto parse_args

:done_parsing

:: Fallback to RECIPIENT_LIST environment variable if no recipients were specified
if "!RECIPIENTS!"=="" (
    set "RECIPIENTS=%RECIPIENT_LIST%"
)

:: Fall back to environment variables if not passed as arguments
if "!SERVER!"=="" (
    if defined DEPLOY_SERVER (
        set "SERVER=!DEPLOY_SERVER!"
    ) else (
        echo [ERROR] Server path is not specified. Set DEPLOY_SERVER environment variable or use --server.
        goto usage
    )
)
if "!USER_NAME!"=="" (
    if defined user (
        set "USER_NAME=!user!"
    ) else (
        echo [ERROR] Username is not specified. Set user environment variable or use --user.
        goto usage
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
        goto usage
    )
)
if "!RECIPIENTS!"=="" (
    if defined RECIPIENT_LIST (
        set "RECIPIENTS=!RECIPIENT_LIST!"
    ) else (
        echo [ERROR] No recipients specified. Pass them as arguments, via --recipients, or set RECIPIENT_LIST.
        goto usage
    )
)

echo ==============================================================================
echo Deployment Initialization
echo ==============================================================================
echo Target Server: !SERVER!
echo Username:      !USER_NAME!
if not "!AUTH_DOMAIN!"=="" echo Domain:        !AUTH_DOMAIN!
echo Recipients:    !RECIPIENTS!
if "!DRY_RUN!"=="1" (
    echo Mode:          DRY RUN - Previewing commands only
) else (
    echo Mode:          LIVE DEPLOYMENT
)
echo ==============================================================================

:: Connect to network share using connect.bat
set "DRY_RUN_ARG="
if "!DRY_RUN!"=="1" set "DRY_RUN_ARG=--dry-run"

set "DOMAIN_ARG="
if not "!AUTH_DOMAIN!"=="" set "DOMAIN_ARG=--domain "!AUTH_DOMAIN!""

call "%~dp0connect_recipients.bat" --server "!SERVER!" --user "!USER_NAME!" !DOMAIN_ARG! --password "!PASS_WORD!" !DRY_RUN_ARG!
if errorlevel 1 (
    echo [ERROR] Connection script failed. Exiting deployment.
    exit /b 1
)

:: Process each recipient
set "SUCCESS_COUNT=0"
set "FAIL_COUNT=0"

for %%R in (!RECIPIENTS!) do (
    if defined TEAMCITY_VERSION echo ##teamcity[blockOpened name='Recipient %%~R']
    echo.
    echo --------------------------------------------------
    echo Processing Recipient: %%~R
    echo --------------------------------------------------

    :: Verify local source folder exists before trying to copy
    if not exist "%%~R" (
        echo [WARNING] Source directory "%%~R" not found locally. Skipping.
        if defined TEAMCITY_VERSION echo ##teamcity[message text='Source directory %%~R not found locally' status='WARNING']
        set /a FAIL_COUNT+=1
    ) else (
        if "!DRY_RUN!"=="1" (
            echo [DRY-RUN] rd /s /q "!SERVER!\%%~R\"
            echo [DRY-RUN] xcopy /Y /I /E "%%~R\*" "!SERVER!\%%~R\"
            set /a SUCCESS_COUNT+=1
        ) else (
            echo Deleting remote directory: "!SERVER!\%%~R\"
            rd /s /q "!SERVER!\%%~R\"
            
            echo Copying files to remote server...
            xcopy /Y /I /E "%%~R\*" "!SERVER!\%%~R\"
            if errorlevel 1 (
                echo [ERROR] xcopy failed for recipient %%~R.
                if defined TEAMCITY_VERSION (
                    echo ##teamcity[message text='xcopy failed for recipient %%~R' status='ERROR']
                    echo ##teamcity[buildProblem description='Failed to deploy recipient %%~R']
                )
                set /a FAIL_COUNT+=1
            ) else (
                echo [SUCCESS] Finished copying %%~R.
                set /a SUCCESS_COUNT+=1
            )
        )
    )
    if defined TEAMCITY_VERSION echo ##teamcity[blockClosed name='Recipient %%~R']
)

echo.
echo ==============================================================================
echo Cleanup
echo ==============================================================================
call "%~dp0disconnect_recipients.bat" --server "!SERVER!" !DRY_RUN_ARG!

echo.
echo ==============================================================================
echo Deployment Summary
echo ==============================================================================
echo Successful: !SUCCESS_COUNT!
echo Failed:     !FAIL_COUNT!
echo ==============================================================================

if !FAIL_COUNT! gtr 0 (
    echo [ERROR] One or more recipients failed to deploy.
    exit /b 1
) else (
    echo [SUCCESS] All recipients deployed successfully.
    exit /b 0
)

:usage
echo.
echo Usage: %SCRIPT_NAME% [options] [recipient1 [recipient2 ...]]
echo.
echo Options:
echo   --server ^<path^>        Target server/UNC path (default: %%DEPLOY_SERVER%%)
echo   --user ^<username^>      Username (default: %%user%%)
echo   --password ^<pwd^>       Password (default: %%password%%)
echo   --recipients ^"list^"    Space-separated list of recipients
echo   --dry-run or /dryrun   Run in dry-run mode (does not execute actual commands)
echo.
echo Environment Variables:
echo   You can set DEPLOY_SERVER, user, password, and RECIPIENT_LIST in your environment
echo   (e.g., in TeamCity parameters) instead of passing command-line arguments.
echo.
exit /b 1
