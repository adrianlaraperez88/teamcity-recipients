# ==============================================================================
# Automated Test Runner for Deployment Scripts
# ==============================================================================
$ErrorActionPreference = "Stop"

# Get workspace root
$wsRoot = Split-Path $PSScriptRoot -Parent
$copyRecipientsScript = Join-Path $wsRoot "copy_recipients.bat"
$deployRobocopyScript = Join-Path $wsRoot "deploy_robocopy_recipients.bat"
$deployPhpScript = Join-Path $wsRoot "deploy_php.ps1"
$deployS3Bat = Join-Path $wsRoot "deploy_s3_cloudfront.bat"
$deployS3Ps1 = Join-Path $wsRoot "deploy_s3_cloudfront.ps1"
$mockConfigDir = Join-Path $PSScriptRoot "mock-config"

$totalTests = 0
$passedTests = 0

function Assert-Contains([string]$output, [string]$pattern, [string]$testName) {
    if ($output.Contains($pattern)) {
        Write-Host "  -> Pattern '$pattern' found." -ForegroundColor Green
    } else {
        Write-Error "Test '$testName' FAILED: Output did not contain expected pattern '$pattern'"
        exit 1
    }
}

function Run-TestCase([string]$name, [scriptblock]$action) {
    Write-Host "Running Test: $name..." -ForegroundColor Cyan
    $global:totalTests++
    try {
        & $action
        $global:passedTests++
        Write-Host "[PASSED] $name`n" -ForegroundColor Green
    }
    catch {
        Write-Host "[FAILED] $name`n" -ForegroundColor Red
        Write-Error $_.Exception.Message
    }
}

# -------------------------------------------------------------------
# Test Case 1: copy_recipients.bat CLI Arguments (Dry-Run)
# -------------------------------------------------------------------
Run-TestCase "copy_recipients.bat with Command-Line Arguments and Domain" {
    # Set up mock source folders
    $mockRec1 = Join-Path $wsRoot "test_recipient1"
    $mockRec2 = Join-Path $wsRoot "test_recipient2"
    New-Item -ItemType Directory -Path $mockRec1 -Force | Out-Null
    New-Item -ItemType Directory -Path $mockRec2 -Force | Out-Null

    try {
        # Run script
        $cmd = "cmd.exe"
        $args = "/c `"$copyRecipientsScript`" --dry-run --server \\mock-server\share --user testuser --domain MOCKDOMAIN --password testpass test_recipient1 test_recipient2"
        
        Write-Host "  Executing: $cmd $args"
        $process = Start-Process $cmd -ArgumentList $args -WorkingDirectory $wsRoot -NoNewWindow -PassThru -RedirectStandardOutput tmp_out.log -RedirectStandardError tmp_err.log -Wait
        $output = Get-Content tmp_out.log -Raw
        Remove-Item tmp_out.log -Force
        Remove-Item tmp_err.log -Force

        # Verify output details using clean single quotes
        Assert-Contains $output 'Target Server: \\mock-server\share' 'Test 1'
        Assert-Contains $output 'Username:      testuser' 'Test 1'
        Assert-Contains $output 'Domain:        MOCKDOMAIN' 'Test 1'
        Assert-Contains $output 'Recipients:    test_recipient1 test_recipient2' 'Test 1'
        Assert-Contains $output 'net use "\\mock-server\share" /user:"MOCKDOMAIN\testuser"' 'Test 1'
        Assert-Contains $output 'rd /s /q "\\mock-server\share\test_recipient1\"' 'Test 1'
        Assert-Contains $output 'xcopy /Y /I /E "test_recipient1\*" "\\mock-server\share\test_recipient1\"' 'Test 1'
        Assert-Contains $output 'net use "\\mock-server\share" /delete' 'Test 1'
        Assert-Contains $output '[SUCCESS] All recipients deployed successfully.' 'Test 1'

        if ($process.ExitCode -ne 0) {
            throw "Script returned non-zero exit code: $($process.ExitCode)"
        }
    }
    finally {
        # Clean up local dummy folders
        Remove-Item $mockRec1 -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $mockRec2 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------------
# Test Case 2: copy_recipients.bat Environment Fallback (Dry-Run)
# -------------------------------------------------------------------
Run-TestCase "copy_recipients.bat Environment Variable Fallbacks" {
    # Set up mock source folders
    $mockRec1 = Join-Path $wsRoot "test_recipient1"
    New-Item -ItemType Directory -Path $mockRec1 -Force | Out-Null

    # Temporarily set env variables
    $origServer = $env:DEPLOY_SERVER
    $origUser = $env:user
    $origDomain = $env:USER_DOMAIN
    $origPass = $env:password
    $origList = $env:RECIPIENT_LIST

    $env:DEPLOY_SERVER = "\\env-server\share"
    $env:user = "envuser"
    $env:USER_DOMAIN = "ENVDOMAIN"
    $env:password = "envpass"
    $env:RECIPIENT_LIST = "test_recipient1"

    try {
        # Run script
        $cmd = "cmd.exe"
        $args = "/c `"$copyRecipientsScript`" --dry-run"
        
        Write-Host "  Executing with env vars: $cmd $args"
        $process = Start-Process $cmd -ArgumentList $args -WorkingDirectory $wsRoot -NoNewWindow -PassThru -RedirectStandardOutput tmp_out.log -RedirectStandardError tmp_err.log -Wait
        $output = Get-Content tmp_out.log -Raw
        Remove-Item tmp_out.log -Force
        Remove-Item tmp_err.log -Force

        # Verify output details using clean single quotes
        Assert-Contains $output 'Target Server: \\env-server\share' 'Test 2'
        Assert-Contains $output 'Username:      envuser' 'Test 2'
        Assert-Contains $output 'Domain:        ENVDOMAIN' 'Test 2'
        Assert-Contains $output 'Recipients:    test_recipient1' 'Test 2'
        Assert-Contains $output 'net use "\\env-server\share" /user:"ENVDOMAIN\envuser"' 'Test 2'

        if ($process.ExitCode -ne 0) {
            throw "Script returned non-zero exit code: $($process.ExitCode)"
        }
    }
    finally {
        # Restore environment variables
        $env:DEPLOY_SERVER = $origServer
        $env:user = $origUser
        $env:USER_DOMAIN = $origDomain
        $env:password = $origPass
        $env:RECIPIENT_LIST = $origList

        # Clean up local dummy folder
        Remove-Item $mockRec1 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------------
# Test Case 3: deploy_robocopy_recipients.bat Command Verification (Dry-Run)
# -------------------------------------------------------------------
Run-TestCase "deploy_robocopy_recipients.bat with Command-Line Arguments" {
    # Run script
    $cmd = "cmd.exe"
    $args = "/c `"$deployRobocopyScript`" --dry-run --server \\robo-server\share --user robouser --domain ROBODOMAIN --password robopass --source . --target-subfolder CUSTOM_DIR"
    
    Write-Host "  Executing: $cmd $args"
    $process = Start-Process $cmd -ArgumentList $args -WorkingDirectory $wsRoot -NoNewWindow -PassThru -RedirectStandardOutput tmp_out.log -RedirectStandardError tmp_err.log -Wait
    $output = Get-Content tmp_out.log -Raw
    Remove-Item tmp_out.log -Force
    Remove-Item tmp_err.log -Force

    # Verify output details using clean single quotes
    Assert-Contains $output 'Target Server:      \\robo-server\share' 'Test 3'
    Assert-Contains $output 'Target Subfolder:  CUSTOM_DIR' 'Test 3'
    Assert-Contains $output 'Domain:             ROBODOMAIN' 'Test 3'
    Assert-Contains $output 'net use "\\robo-server\share" /user:"ROBODOMAIN\robouser"' 'Test 3'
    Assert-Contains $output 'robocopy "." "\\robo-server\share\CUSTOM_DIR" /MIR /FFT /Z /R:5 /W:60 /MT:16 /LOG:robocopy_log.txt /XF exclude.txt' 'Test 3'
    Assert-Contains $output 'net use "\\robo-server\share" /delete' 'Test 3'

    if ($process.ExitCode -ne 0) {
        throw "Script returned non-zero exit code: $($process.ExitCode)"
    }
}

# -------------------------------------------------------------------
# Test Case 4: deploy_php.ps1 Installation & SkipIis (Dry-Run)
# -------------------------------------------------------------------
Run-TestCase "deploy_php.ps1 Update check, configurations and -SkipIis" {
    # Run script
    Write-Host "  Executing: powershell.exe -File $deployPhpScript -PhpMajorVersion '8.3' -RepoConfigDir '$mockConfigDir' -DryRun -SkipIis"
    
    $output = powershell.exe -ExecutionPolicy Bypass -File $deployPhpScript -PhpMajorVersion "8.3" -RepoConfigDir $mockConfigDir -DryRun -SkipIis 2>&1 | Out-String

    # Verify output details
    Assert-Contains $output 'Checking windows.php.net for latest PHP 8.3 release...' 'Test 4'
    Assert-Contains $output 'Latest available version: 8.3' 'Test 4'
    Assert-Contains $output 'IIS service management skipped via -SkipIis.' 'Test 4'
    Assert-Contains $output "Would copy php.ini from $mockConfigDir\php.ini to C:\PHP\PHP8.3\php.ini" 'Test 4'
    Assert-Contains $output "Would copy custom extensions from $mockConfigDir\ext to C:\PHP\PHP8.3\ext:" 'Test 4'
    Assert-Contains $output 'Would copy test_ext.dll' 'Test 4'
    Assert-Contains $output 'Deployment simulation completed successfully.' 'Test 4'
}

# -------------------------------------------------------------------
# Test Case 4b: deploy_php.ps1 Installed Version Detection
# -------------------------------------------------------------------
Run-TestCase "deploy_php.ps1 Detects Installed PHP Version Correctly" {
    $existingPhpDir = "C:\php-8.3"
    if (Test-Path (Join-Path $existingPhpDir "php.exe")) {
        Write-Host "  Executing against existing PHP installation: $existingPhpDir"
        $output = powershell.exe -ExecutionPolicy Bypass -File $deployPhpScript -PhpMajorVersion "8.3" -TargetPhpDir $existingPhpDir -RepoConfigDir $mockConfigDir -DryRun -SkipIis 2>&1 | Out-String

        Assert-Contains $output 'Installed : 8.3.32' 'Test 4b'
        Assert-Contains $output 'Available : 8.3' 'Test 4b'
        if ($output.Contains('Unable to determine installed PHP version.')) {
            throw "Test 4b FAILED: Output contained unexpected warning 'Unable to determine installed PHP version.'"
        }
    } else {
        Write-Host "  Skipping active php.exe test because $existingPhpDir was not found."
    }
}

# -------------------------------------------------------------------
# Test Case 5: deploy_s3_cloudfront.bat Multi-Recipient (Dry-Run)
# -------------------------------------------------------------------
Run-TestCase "deploy_s3_cloudfront.bat Multi-Recipient CLI Arguments" {
    # Set up mock source folders
    $mockRec1 = Join-Path $wsRoot "s3_rec1"
    $mockRec2 = Join-Path $wsRoot "s3_rec2"
    New-Item -ItemType Directory -Path $mockRec1 -Force | Out-Null
    New-Item -ItemType Directory -Path $mockRec2 -Force | Out-Null

    try {
        $cmd = "cmd.exe"
        $args = "/c `"$deployS3Bat`" --dry-run --bucket my-test-bucket --distribution-id E12345EXAMPLE --region us-west-2 --prefix apps --delete s3_rec1 s3_rec2"
        
        Write-Host "  Executing: $cmd $args"
        $process = Start-Process $cmd -ArgumentList $args -WorkingDirectory $wsRoot -NoNewWindow -PassThru -RedirectStandardOutput tmp_out.log -RedirectStandardError tmp_err.log -Wait
        $output = Get-Content tmp_out.log -Raw
        Remove-Item tmp_out.log -Force
        Remove-Item tmp_err.log -Force

        Assert-Contains $output 'S3 Bucket:         my-test-bucket' 'Test 5'
        Assert-Contains $output 'AWS Region:        us-west-2' 'Test 5'
        Assert-Contains $output 'S3 Prefix:         apps' 'Test 5'
        Assert-Contains $output 'Recipients:        s3_rec1 s3_rec2' 'Test 5'
        Assert-Contains $output 'Sync --delete:     Enabled' 'Test 5'
        Assert-Contains $output '[DRY-RUN] aws s3 sync "s3_rec1" "s3://my-test-bucket/apps/s3_rec1" --region us-west-2 --delete' 'Test 5'
        Assert-Contains $output '[DRY-RUN] aws s3 sync "s3_rec2" "s3://my-test-bucket/apps/s3_rec2" --region us-west-2 --delete' 'Test 5'
        Assert-Contains $output '[DRY-RUN] aws cloudfront create-invalidation --distribution-id E12345EXAMPLE --paths /apps/s3_rec1/* /apps/s3_rec2/*' 'Test 5'
        Assert-Contains $output '[SUCCESS] S3 and CloudFront deployment completed successfully.' 'Test 5'

        if ($process.ExitCode -ne 0) {
            throw "Script returned non-zero exit code: $($process.ExitCode)"
        }
    }
    finally {
        Remove-Item $mockRec1 -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $mockRec2 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------------
# Test Case 6: deploy_s3_cloudfront.bat Single-Source Env Vars (Dry-Run)
# -------------------------------------------------------------------
Run-TestCase "deploy_s3_cloudfront.bat Single-Source & Environment Variables" {
    $origBucket = $env:AWS_S3_BUCKET
    $origDist = $env:CLOUDFRONT_DISTRIBUTION_ID
    $origRegion = $env:AWS_REGION
    $origSource = $env:SOURCE_DIR

    $env:AWS_S3_BUCKET = "env-bucket-demo"
    $env:CLOUDFRONT_DISTRIBUTION_ID = "EDISTRIB789"
    $env:AWS_REGION = "eu-west-1"
    $env:SOURCE_DIR = "."

    try {
        $cmd = "cmd.exe"
        $args = "/c `"$deployS3Bat`" --dry-run"
        
        Write-Host "  Executing: $cmd $args"
        $process = Start-Process $cmd -ArgumentList $args -WorkingDirectory $wsRoot -NoNewWindow -PassThru -RedirectStandardOutput tmp_out.log -RedirectStandardError tmp_err.log -Wait
        $output = Get-Content tmp_out.log -Raw
        Remove-Item tmp_out.log -Force
        Remove-Item tmp_err.log -Force

        Assert-Contains $output 'S3 Bucket:         env-bucket-demo' 'Test 6'
        Assert-Contains $output 'AWS Region:        eu-west-1' 'Test 6'
        Assert-Contains $output 'Deployment Mode:   Single Source Folder Mode' 'Test 6'
        Assert-Contains $output '[DRY-RUN] aws s3 sync "." "s3://env-bucket-demo" --region eu-west-1' 'Test 6'
        Assert-Contains $output '[DRY-RUN] aws cloudfront create-invalidation --distribution-id EDISTRIB789 --paths /*' 'Test 6'
        Assert-Contains $output '[SUCCESS] S3 and CloudFront deployment completed successfully.' 'Test 6'

        if ($process.ExitCode -ne 0) {
            throw "Script returned non-zero exit code: $($process.ExitCode)"
        }
    }
    finally {
        $env:AWS_S3_BUCKET = $origBucket
        $env:CLOUDFRONT_DISTRIBUTION_ID = $origDist
        $env:AWS_REGION = $origRegion
        $env:SOURCE_DIR = $origSource
    }
}

# -------------------------------------------------------------------
# Test Case 7: deploy_s3_cloudfront.ps1 Multi-Recipient (Dry-Run)
# -------------------------------------------------------------------
Run-TestCase "deploy_s3_cloudfront.ps1 Multi-Recipient and Invalidation" {
    $mockRec1 = Join-Path $wsRoot "s3_ps_rec1"
    New-Item -ItemType Directory -Path $mockRec1 -Force | Out-Null

    try {
        Write-Host "  Executing: powershell.exe -File $deployS3Ps1 -Bucket 'ps-test-bucket' -DistributionId 'E999EXAMPLE' -Region 'us-east-1' -S3Prefix 'clients' -Recipients 's3_ps_rec1' -Delete -DryRun"
        $output = powershell.exe -ExecutionPolicy Bypass -File $deployS3Ps1 -Bucket 'ps-test-bucket' -DistributionId 'E999EXAMPLE' -Region 'us-east-1' -S3Prefix 'clients' -Recipients 's3_ps_rec1' -Delete -DryRun 2>&1 | Out-String

        Assert-Contains $output 'S3 Bucket:         ps-test-bucket' 'Test 7'
        Assert-Contains $output 'S3 Prefix:         clients' 'Test 7'
        Assert-Contains $output 'Recipients:        s3_ps_rec1' 'Test 7'
        Assert-Contains $output '[DRY-RUN] aws s3 sync "s3_ps_rec1" "s3://ps-test-bucket/clients/s3_ps_rec1" --region us-east-1 --delete' 'Test 7'
        Assert-Contains $output '[DRY-RUN] aws cloudfront create-invalidation --distribution-id E999EXAMPLE --paths /clients/s3_ps_rec1/*' 'Test 7'
        Assert-Contains $output '[SUCCESS] S3 and CloudFront deployment completed successfully.' 'Test 7'
    }
    finally {
        Remove-Item $mockRec1 -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------------
# Test Case 8: deploy_s3_cloudfront.ps1 Single Source with SkipInvalidation
# -------------------------------------------------------------------
Run-TestCase "deploy_s3_cloudfront.ps1 Single Source and SkipInvalidation" {
    Write-Host "  Executing: powershell.exe -File $deployS3Ps1 -Bucket 'ps-single-bucket' -SourcePath '.' -S3Prefix 'site' -SkipInvalidation -DryRun"
    $output = powershell.exe -ExecutionPolicy Bypass -File $deployS3Ps1 -Bucket 'ps-single-bucket' -SourcePath '.' -S3Prefix 'site' -SkipInvalidation -DryRun 2>&1 | Out-String

    Assert-Contains $output 'S3 Bucket:         ps-single-bucket' 'Test 8'
    Assert-Contains $output 'S3 Prefix:         site' 'Test 8'
    Assert-Contains $output 'Deployment Mode:   Single Source Folder Mode' 'Test 8'
    Assert-Contains $output 'Invalidation:      Skipped (-SkipInvalidation)' 'Test 8'
    Assert-Contains $output '[DRY-RUN] aws s3 sync "." "s3://ps-single-bucket/site" --region us-east-1' 'Test 8'
    Assert-Contains $output '[SUCCESS] S3 and CloudFront deployment completed successfully.' 'Test 8'
}

# -------------------------------------------------------------------
# SUMMARY
# -------------------------------------------------------------------
Write-Host "`n======================================================================" -ForegroundColor Cyan
Write-Host "TEST SUITE SUMMARY" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Passed Tests: $passedTests / $totalTests" -ForegroundColor $(if ($passedTests -eq $totalTests) { "Green" } else { "Red" })
Write-Host "======================================================================" -ForegroundColor Cyan

if ($passedTests -eq $totalTests) {
    Write-Host "ALL TESTS PASSED SUCCESSFULLY!" -ForegroundColor Green
    exit 0
} else {
    Write-Error "SOME TESTS FAILED!"
    exit 1
}
