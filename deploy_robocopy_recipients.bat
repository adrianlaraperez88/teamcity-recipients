@echo off
setlocal enabledelayedexpansion
set "SCRIPT_NAME=%~nx0"

:: ==============================================================================
:: Reusable Robocopy Deployment Script
:: ==============================================================================
:: Synchronizes a local source directory with a remote target directory using
:: robocopy. Reuses connect.bat and disconnect.bat.
::
:: Usage:
::   deploy_robocopy.bat [options]
::
:: Options:
::   --server <path>            Target server/UNC path (default: %DEPLOY_SERVER%)
::   --user <username>          Username (default: %user%)
::   --domain <domain>          Active Directory domain (default: %USER_DOMAIN% or %DOMAIN%)
::   --password <pwd>           Password (default: %password%)
::   --source <dir>             Source directory (default: .)
::   --target-subfolder <name>  Target directory on server (default: %TARGET_SUBFOLDER% or shared)
::   --dry-run or /dryrun       Run in dry-run mode (does not execute actual commands)
:: ==============================================================================

:: Defaults
set "SERVER="
set "USER_NAME="
set "AUTH_DOMAIN="
set "PASS_WORD="
set "SOURCE=."
set "TARGET_SUBFOLDER="
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
if /i "%~1"=="--source" (
    set "SOURCE=%~2"
    shift & shift
    goto parse_args
)
if /i "%~1"=="--target-subfolder" (
    set "TARGET_SUBFOLDER=%~2"
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
if "!TARGET_SUBFOLDER!"=="" (
    if defined TARGET_SUBFOLDER (
        set "TARGET_SUBFOLDER=!TARGET_SUBFOLDER!"
    ) else (
        set "TARGET_SUBFOLDER=shared"
    )
)

:: Validate source directory
if not exist "!SOURCE!" (
    echo [ERROR] Source directory "!SOURCE!" does not exist.
    exit /b 1
)

echo ==============================================================================
echo Robocopy Deployment Initialization
echo ==============================================================================
echo Target Server:      !SERVER!
echo Target Subfolder:  !TARGET_SUBFOLDER!
echo Source Directory:   !SOURCE!
echo Username:           !USER_NAME!
if not "!AUTH_DOMAIN!"=="" echo Domain:             !AUTH_DOMAIN!
if "!DRY_RUN!"=="1" (
    echo Mode:               DRY RUN - Previewing commands only
) else (
    echo Mode:               LIVE DEPLOYMENT
)
echo ==============================================================================

:: Build dry-run argument flag for connect/disconnect delegation
set "DRY_RUN_ARG="
if "!DRY_RUN!"=="1" set "DRY_RUN_ARG=--dry-run"

set "DOMAIN_ARG="
if not "!AUTH_DOMAIN!"=="" set "DOMAIN_ARG=--domain "!AUTH_DOMAIN!""

:: Connect to network share using connect.bat
call "%~dp0connect_recipients.bat" --server "!SERVER!" --user "!USER_NAME!" !DOMAIN_ARG! --password "!PASS_WORD!" !DRY_RUN_ARG!
if errorlevel 1 (
    echo [ERROR] Connection script failed. Exiting deployment.
    exit /b 1
)

:: Perform robocopy
if defined TEAMCITY_VERSION echo ##teamcity[blockOpened name='Robocopy Sync']
echo.
echo Running robocopy...
set "TARGET_PATH=!SERVER!\!TARGET_SUBFOLDER!"

if "!DRY_RUN!"=="1" (
    echo [DRY-RUN] robocopy "!SOURCE!" "!TARGET_PATH!" /MIR /FFT /Z /R:5 /W:60 /MT:16 /LOG:robocopy_log.txt /XF exclude.txt
    set "ROBO_ERROR=0"
) else (
    :: Run robocopy. Note that robocopy exit codes < 8 indicate success.
    robocopy "!SOURCE!" "!TARGET_PATH!" /MIR /FFT /Z /R:5 /W:60 /MT:16 /LOG:robocopy_log.txt /XF exclude.txt
    set "ROBO_ERROR=!errorlevel!"
    
    :: Print log file contents if desired or just report success/failure
    if exist robocopy_log.txt (
        echo Robocopy finished. See robocopy_log.txt for details.
    )
)
if defined TEAMCITY_VERSION echo ##teamcity[blockClosed name='Robocopy Sync']

:: Disconnect from server using disconnect.bat
echo.
echo ==============================================================================
echo Cleanup
echo ==============================================================================
call "%~dp0disconnect_recipients.bat" --server "!SERVER!" !DRY_RUN_ARG!

echo.
echo ==============================================================================
echo Summary
echo ==============================================================================
if !ROBO_ERROR! geq 8 (
    echo [ERROR] Robocopy failed with exit code !ROBO_ERROR!.
    if defined TEAMCITY_VERSION echo ##teamcity[buildProblem description='Robocopy failed with exit code !ROBO_ERROR!']
    exit /b 1
) else (
    echo [SUCCESS] Synchronization completed successfully. Robocopy status: !ROBO_ERROR!
    exit /b 0
)

:usage
echo.
echo Usage: %SCRIPT_NAME% [options]
echo.
echo Options:
echo   --server <path>            Target server/UNC path (default: %%DEPLOY_SERVER%%)
echo   --user <username>          Username (default: %%user%%)
echo   --password <pwd>           Password (default: %%password%%)
echo   --source <dir>             Source directory (default: .)
echo   --target-subfolder <name>  Target directory on server (default: ISGOEV2)
echo   --dry-run or /dryrun       Run in dry-run mode (does not execute actual commands)
echo.
echo Environment Variables:
echo   You can set DEPLOY_SERVER, user, and password in your environment.
echo.
exit /b 1
