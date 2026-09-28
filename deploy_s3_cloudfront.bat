@echo off
setlocal
:: ==============================================================================
:: AWS S3 and CloudFront Deployment Launcher
:: ==============================================================================
:: Invokes the PowerShell S3 & CloudFront deployment engine with all arguments
:: and environment variables intact.
:: ==============================================================================
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0deploy_s3_cloudfront.ps1" %*
exit /b %ERRORLEVEL%
