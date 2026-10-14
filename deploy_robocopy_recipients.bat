@echo off
setlocal enabledelayedexpansion
set "SCRIPT_NAME=%~nx0"

:: ==============================================================================
:: Reusable Robocopy Recipients Deployment Script
:: ==============================================================================
:: Synchronizes local recipient directories with remote target directories using
:: robocopy mirroring, exclusions, and automated connection management.
:: Reuses connect_recipients.bat and disconnect_recipients.bat.
::
:: Usage:
::   deploy_robocopy_recipients.bat [options] [recipient1 [recipient2 ...]]
::
:: Options:
::   --server <path>            Target server/UNC path (default: %PRODWEB18SRV% or %DEPLOY_SERVER%)
::   --user <username>          Username (default: %user%)
::   --domain <domain>          Active Directory domain (default: %USER_DOMAIN% or %DOMAIN% or infsalesgroup)
::   --password <pwd>           Password (default: %password%)
::   --source <dir>             Source directory (default: .)
::   --target-base <name>       Base target directory (default: %TARGET_BASE% or InfinitySales)
::   --recipients "list"        Space-separated list of recipient folders
::   --dry-run or /dryrun       Run in dry-run mode (does not execute actual commands)
:: ==============================================================================

:: Defaults
set "SERVER="
set "USER_NAME="
set "AUTH_DOMAIN="
set "PASS_WORD="
set "SOURCE=."
set "TARGET_BASE="
set "RECIPIENTS="
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
if /i "%~1"=="--target-base" (
    set "TARGET_BASE=%~2"
    shift & shift
    goto parse_args
)
if /i "%~1"=="--target-subfolder" (
    set "TARGET_BASE=%~2"
    shift & shift
    goto parse_args
)
if /i "%~1"=="--recipients" (
    set "RECIPIENTS=%~2"
    shift & shift
    goto parse_args
)

:: Treat positional arguments as recipient names
if not "%~1"=="" (
    if "!RECIPIENTS!"=="" (
        set "RECIPIENTS=%~1"
    ) else (
        set "RECIPIENTS=!RECIPIENTS! %~1"
    )
)
shift
goto parse_args

:done_parsing

:: Fall back to environment variables if not passed as arguments
if "!SERVER!"=="" (
    if defined PRODWEB18SRV (
        set "SERVER=!PRODWEB18SRV!"
    ) else if defined DEPLOY_SERVER (
        set "SERVER=!DEPLOY_SERVER!"
    ) else (
        echo [ERROR] Server path is not specified. Set PRODWEB18SRV or DEPLOY_SERVER or use --server.
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
    ) else (
        set "AUTH_DOMAIN=infsalesgroup"
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
if "!TARGET_BASE!"=="" (
    if defined TARGET_BASE (
        set "TARGET_BASE=!TARGET_BASE!"
    ) else (
        set "TARGET_BASE=InfinitySales"
    )
)
if "!RECIPIENTS!"=="" (
    if defined RECIPIENT_LIST (
        set "RECIPIENTS=!RECIPIENT_LIST!"
    )
)

echo ==============================================================================
echo Robocopy Recipients Deployment Initialization
echo ==============================================================================
echo Target Server:      !SERVER!
echo Target Subfolder:  !TARGET_BASE!
echo Source Directory:   !SOURCE!
if not "!RECIPIENTS!"=="" echo Recipients List:    !RECIPIENTS!
echo Username:           !USER_NAME!
if not "!AUTH_DOMAIN!"=="" echo Domain:             !AUTH_DOMAIN!
if "!DRY_RUN!"=="1" (
    echo Mode:               DRY RUN - Previewing commands only
) else (
    echo Mode:               LIVE DEPLOYMENT
)
echo ==============================================================================

:: Build dry-run and domain argument flags
set "DRY_RUN_ARG="
if "!DRY_RUN!"=="1" set "DRY_RUN_ARG=--dry-run"

set "DOMAIN_ARG="
if not "!AUTH_DOMAIN!"=="" set "DOMAIN_ARG=--domain "!AUTH_DOMAIN!""

:: 1. Connect to network share using connect_recipients.bat
call "%~dp0connect_recipients.bat" --server "!SERVER!" --user "!USER_NAME!" !DOMAIN_ARG! --password "!PASS_WORD!" !DRY_RUN_ARG!
if errorlevel 1 (
    echo [ERROR] Connection script failed. Exiting deployment.
    exit /b 1
)

:: 2. Optional: Pull common base files from TeamCity agent if path exists
if defined teamcity.agent.home.dir (
    if exist "%teamcity.agent.home.dir%/common/infinity-sales/_prod" (
        echo [INFO] Syncing common base files from agent cache...
        if "!DRY_RUN!"=="1" (
            echo [DRY-RUN] robocopy "%teamcity.agent.home.dir%/common/infinity-sales/_prod" "." /E /FFT /Z /R:5 /W:60 /MT:16 /NFL /NDL /NS /NP
        ) else (
            robocopy "%teamcity.agent.home.dir%/common/infinity-sales/_prod" "." /E /FFT /Z /R:5 /W:60 /MT:16 /NFL /NDL /NS /NP
        )
    )
)

:: 3. Create exclusion file
echo .\.git\ > exclude.txt
echo .\.svn >> exclude.txt
echo exclude.txt >> exclude.txt

:: 4. Deploy Recipients or Root Directory
set "HAS_ERROR=0"

if "!RECIPIENTS!"=="" (
    :: Single target deployment to %SERVER%\%TARGET_BASE%\
    if defined TEAMCITY_VERSION echo ##teamcity[blockOpened name='Robocopy Sync']
    echo.
    echo [INFO] Deploying source to !SERVER!\!TARGET_BASE!\...
    
    if exist robocopy_log.txt del robocopy_log.txt

    if "!DRY_RUN!"=="1" (
        echo [DRY-RUN] robocopy "!SOURCE!" "!SERVER!\!TARGET_BASE!" /MIR /FFT /Z /R:5 /W:60 /MT:16 /LOG:robocopy_log.txt /XF exclude.txt
    ) else (
        robocopy "!SOURCE!" "!SERVER!\!TARGET_BASE!" /MIR /FFT /Z /R:5 /W:60 /MT:16 /LOG:robocopy_log.txt /XF exclude.txt
        if errorlevel 8 set "HAS_ERROR=1"
    )
    if defined TEAMCITY_VERSION echo ##teamcity[blockClosed name='Robocopy Sync']
) else (
    :: Multi-recipient loop deployment
    for %%R in (!RECIPIENTS!) do (
        if defined TEAMCITY_VERSION echo ##teamcity[blockOpened name='Recipient %%~R']
        echo.
        echo ----------------------------------------------------------------------
        echo [INFO] Processing Recipient: %%~R
        echo ----------------------------------------------------------------------

        set "REC_SRC=!SOURCE!"
        if exist "%%~R" set "REC_SRC=%%~R"
        set "REC_DEST=!SERVER!\!TARGET_BASE!\%%~R\"

        if exist "robocopy_log_%%~R.txt" del "robocopy_log_%%~R.txt"

        if "!DRY_RUN!"=="1" (
            echo [DRY-RUN] robocopy "!REC_SRC!" "!REC_DEST!" /MIR /FFT /Z /R:5 /W:60 /MT:16 /LOG:robocopy_log_%%~R.txt /XF exclude.txt
        ) else (
            echo Copying from !REC_SRC! to !REC_DEST!...
            robocopy "!REC_SRC!" "!REC_DEST!" /MIR /FFT /Z /R:5 /W:60 /MT:16 /LOG:robocopy_log_%%~R.txt /XF exclude.txt
            if errorlevel 8 (
                echo [ERROR] Robocopy failed for recipient %%~R.
                if defined TEAMCITY_VERSION echo ##teamcity[message text='Robocopy failed for %%~R' status='ERROR']
                set "HAS_ERROR=1"
            ) else (
                echo [SUCCESS] Recipient %%~R synchronized successfully.
            )
        )
        if defined TEAMCITY_VERSION echo ##teamcity[blockClosed name='Recipient %%~R']
    )
)

:: 5. Cleanup exclusion file
if exist exclude.txt del exclude.txt

:: 6. Disconnect from server using disconnect_recipients.bat
echo.
echo ==============================================================================
echo Cleanup
echo ==============================================================================
call "%~dp0disconnect_recipients.bat" --server "!SERVER!" !DRY_RUN_ARG!

:: 7. Summary
echo.
echo ==============================================================================
echo Summary
echo ==============================================================================
if "!HAS_ERROR!"=="1" (
    echo [ERROR] One or more Robocopy synchronizations failed.
    if defined TEAMCITY_VERSION echo ##teamcity[buildProblem description='Robocopy deployment failed']
    exit /b 1
) else (
    echo [SUCCESS] Robocopy deployment completed successfully!
    exit /b 0
)

:usage
echo.
echo Usage: %SCRIPT_NAME% [options] [recipient1 [recipient2 ...]]
echo.
echo Options:
echo   --server <path>            Target server/UNC path (default: %%PRODWEB18SRV%% or %%DEPLOY_SERVER%%)
echo   --user <username>          Username (default: %%user%%)
echo   --domain <domain>          Domain (default: infsalesgroup)
echo   --password <pwd>           Password (default: %%password%%)
echo   --source <dir>             Source directory (default: .)
echo   --target-base <name>       Base subfolder on server (default: InfinitySales)
echo   --recipients "list"        Space-separated list of recipients
echo   --dry-run or /dryrun       Run in dry-run mode
echo.
exit /b 1
