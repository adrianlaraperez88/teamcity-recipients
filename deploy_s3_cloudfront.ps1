[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Mandatory=$false)]
    [string]$Bucket = $(if ($env:AWS_S3_BUCKET) { $env:AWS_S3_BUCKET } else { $env:S3_BUCKET }),

    [Parameter(Mandatory=$false)]
    [Alias("distribution-id", "dist-id")]
    [string]$DistributionId = $(if ($env:CLOUDFRONT_DISTRIBUTION_ID) { $env:CLOUDFRONT_DISTRIBUTION_ID } else { $env:CLOUDFRONT_ID }),

    [Parameter(Mandatory=$false)]
    [string]$Region = $(if ($env:AWS_REGION) { $env:AWS_REGION } elseif ($env:AWS_DEFAULT_REGION) { $env:AWS_DEFAULT_REGION } else { "us-east-1" }),

    [Parameter(Mandatory=$false)]
    [Alias("source", "source-dir", "sourcedir")]
    [string]$SourcePath = $(if ($env:SOURCE_DIR) { $env:SOURCE_DIR } else { $null }),

    [Parameter(Mandatory=$false)]
    [Alias("prefix", "s3-prefix")]
    [string]$S3Prefix = $(if ($env:S3_PREFIX) { $env:S3_PREFIX } else { "" }),

    [Parameter(Mandatory=$false, Position=0, ValueFromRemainingArguments=$true)]
    [Alias("recipient")]
    [string[]]$Recipients = $(if ($env:RECIPIENT_LIST) { $env:RECIPIENT_LIST -split '\s+' } else { @() }),

    [Parameter(Mandatory=$false)]
    [Alias("invalidation-paths", "invalidation-path", "paths")]
    [string[]]$InvalidationPaths = $(if ($env:INVALIDATION_PATHS) { $env:INVALIDATION_PATHS -split '\s+' } else { $null }),

    [Parameter(Mandatory=$false)]
    [switch]$Delete,

    [Parameter(Mandatory=$false)]
    [Alias("skip-invalidation", "no-invalidation")]
    [switch]$SkipInvalidation,

    [Parameter(Mandatory=$false)]
    [Alias("dry-run", "preview")]
    [switch]$DryRun,

    [Parameter(Mandatory=$false)]
    [string]$AwsCliPath = "aws"
)

# -------------------------------------------------------------------
# TEAMCITY LOG WRAPPERS
# -------------------------------------------------------------------
function Write-TCBlockOpen([string]$name) {
    if ($env:TEAMCITY_VERSION) {
        Write-Output "##teamcity[blockOpened name='$name']"
    }
}

function Write-TCBlockClose([string]$name) {
    if ($env:TEAMCITY_VERSION) {
        Write-Output "##teamcity[blockClosed name='$name']"
    }
}

function Write-TCMessage([string]$text, [string]$status) {
    if ($env:TEAMCITY_VERSION) {
        $escaped = $text -replace "'", "|'" -replace "\[", "|[" -replace "\]", "|]"
        Write-Output "##teamcity[message text='$escaped' status='$status']"
    }
}

function Write-TCBuildProblem([string]$description) {
    if ($env:TEAMCITY_VERSION) {
        $escaped = $description -replace "'", "|'" -replace "\[", "|[" -replace "\]", "|]"
        Write-Output "##teamcity[buildProblem description='$escaped']"
    }
}

# -------------------------------------------------------------------
# VALIDATION & SETUP
# -------------------------------------------------------------------
$scriptName = $MyInvocation.MyCommand.Name

if ([string]::IsNullOrWhiteSpace($Bucket)) {
    Write-Error "S3 Bucket is required. Either set AWS_S3_BUCKET / S3_BUCKET environment variable or pass -Bucket parameter (e.g. -Bucket 'my-deploy-bucket')."
    Write-Host ""
    Write-Host "Usage: powershell -File $scriptName -Bucket <bucket-name> [-DistributionId <id>] [-Region <region>] [-SourcePath <dir>] [-S3Prefix <prefix>] [-Recipients <list>] [-Delete] [-SkipInvalidation] [-DryRun]"
    exit 1
}

# Normalize S3 prefix (strip leading and trailing slashes)
$cleanPrefix = $S3Prefix.Trim("/").Trim("\")

# Normalize recipients list
$recipientList = @()
if ($Recipients) {
    foreach ($r in $Recipients) {
        if ($r) {
            $splitItems = $r -split '[\s,]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("-") }
            $recipientList += $splitItems
        }
    }
}

# Determine mode: Multi-recipient vs Single Source
$isMultiRecipient = ($recipientList.Count -gt 0)

if (-not $isMultiRecipient -and [string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = "."
}

Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "AWS S3 and CloudFront Deployment Initialization" -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "S3 Bucket:         $Bucket"
Write-Host "AWS Region:        $Region"
Write-Host "S3 Prefix:         $(if ($cleanPrefix) { $cleanPrefix } else { "(root)" })"
if ($isMultiRecipient) {
    Write-Host "Deployment Mode:   Multi-Recipient Mode"
    Write-Host "Recipients:        $($recipientList -join ' ')"
} else {
    Write-Host "Deployment Mode:   Single Source Folder Mode"
    Write-Host "Source Path:       $SourcePath"
}
Write-Host "CloudFront Dist:   $(if ($DistributionId) { $DistributionId } else { "(None / Skipped)" })"
Write-Host "Sync --delete:     $(if ($Delete) { "Enabled" } else { "Disabled" })"
Write-Host "Invalidation:      $(if ($SkipInvalidation) { "Skipped (-SkipInvalidation)" } elseif ($DistributionId) { "Active" } else { "No Distribution ID provided" })"
Write-Host "Execution Mode:    $(if ($DryRun) { "DRY RUN - Previewing commands only" } else { "LIVE DEPLOYMENT" })"
Write-Host "==============================================================================" -ForegroundColor Cyan

# Verify AWS CLI in live mode
if (-not $DryRun) {
    $awsCmd = Get-Command $AwsCliPath -ErrorAction SilentlyContinue
    if (-not $awsCmd) {
        Write-Error "AWS CLI executable ('$AwsCliPath') was not found in PATH. Please install AWS CLI or ensure it is available in PATH."
        exit 1
    }
}

$successCount = 0
$failCount = 0
$autoInvalidationPaths = @()

# -------------------------------------------------------------------
# 1. S3 SYNC / DEPLOYMENT
# -------------------------------------------------------------------
Write-TCBlockOpen "1. S3 Sync Deployment"

if ($isMultiRecipient) {
    foreach ($rec in $recipientList) {
        Write-TCBlockOpen "Recipient $rec"
        Write-Host ""
        Write-Host "--------------------------------------------------" -ForegroundColor Yellow
        Write-Host "Processing Recipient: $rec" -ForegroundColor Yellow
        Write-Host "--------------------------------------------------" -ForegroundColor Yellow

        if (-not (Test-Path $rec)) {
            Write-Host "[WARNING] Source directory '$rec' not found locally. Skipping." -ForegroundColor Yellow
            Write-TCMessage "Source directory $rec not found locally" "WARNING"
            $failCount++
        } else {
            # Construct target S3 URI
            $targetUri = "s3://$Bucket"
            if ($cleanPrefix) {
                $targetUri += "/$cleanPrefix"
            }
            $targetUri += "/$rec"

            # Construct invalidation path
            $invPath = ""
            if ($cleanPrefix) {
                $invPath += "/$cleanPrefix"
            }
            $invPath += "/$rec/*"
            $autoInvalidationPaths += $invPath

            $syncArgs = @("s3", "sync", "`"$rec`"", "`"$targetUri`"", "--region", $Region)
            if ($Delete) {
                $syncArgs += "--delete"
            }

            $cmdDisplay = "aws " + ($syncArgs -join " ")
            if ($DryRun) {
                Write-Host "[DRY-RUN] $cmdDisplay" -ForegroundColor Green
                $successCount++
            } else {
                Write-Host "Executing: $cmdDisplay" -ForegroundColor Cyan
                & $AwsCliPath $syncArgs
                if ($LASTEXITCODE -ne 0) {
                    Write-Host "[ERROR] AWS S3 sync failed for recipient $rec (Exit Code: $LASTEXITCODE)." -ForegroundColor Red
                    Write-TCMessage "AWS S3 sync failed for recipient $rec" "ERROR"
                    Write-TCBuildProblem "Failed to deploy recipient $rec to S3"
                    $failCount++
                } else {
                    Write-Host "[SUCCESS] Finished deploying recipient $rec to $targetUri" -ForegroundColor Green
                    $successCount++
                }
            }
        }
        Write-TCBlockClose "Recipient $rec"
    }
} else {
    Write-TCBlockOpen "Deploy Source: $SourcePath"
    Write-Host ""
    Write-Host "--------------------------------------------------" -ForegroundColor Yellow
    Write-Host "Processing Source: $SourcePath" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------" -ForegroundColor Yellow

    if (-not (Test-Path $SourcePath)) {
        Write-Host "[ERROR] Source path '$SourcePath' not found locally." -ForegroundColor Red
        Write-TCMessage "Source path $SourcePath not found locally" "ERROR"
        Write-TCBuildProblem "Source path $SourcePath not found locally"
        $failCount++
    } else {
        $targetUri = "s3://$Bucket"
        if ($cleanPrefix) {
            $targetUri += "/$cleanPrefix"
        }

        $invPath = if ($cleanPrefix) { "/$cleanPrefix/*" } else { "/*" }
        $autoInvalidationPaths += $invPath

        $syncArgs = @("s3", "sync", "`"$SourcePath`"", "`"$targetUri`"", "--region", $Region)
        if ($Delete) {
            $syncArgs += "--delete"
        }

        $cmdDisplay = "aws " + ($syncArgs -join " ")
        if ($DryRun) {
            Write-Host "[DRY-RUN] $cmdDisplay" -ForegroundColor Green
            $successCount++
        } else {
            Write-Host "Executing: $cmdDisplay" -ForegroundColor Cyan
            & $AwsCliPath $syncArgs
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[ERROR] AWS S3 sync failed for $SourcePath (Exit Code: $LASTEXITCODE)." -ForegroundColor Red
                Write-TCMessage "AWS S3 sync failed for $SourcePath" "ERROR"
                Write-TCBuildProblem "Failed to deploy $SourcePath to S3"
                $failCount++
            } else {
                Write-Host "[SUCCESS] Finished deploying $SourcePath to $targetUri" -ForegroundColor Green
                $successCount++
            }
        }
    }
    Write-TCBlockClose "Deploy Source: $SourcePath"
}

Write-TCBlockClose "1. S3 Sync Deployment"

# -------------------------------------------------------------------
# 2. CLOUDFRONT CACHE INVALIDATION
# -------------------------------------------------------------------
if (-not $SkipInvalidation -and [string]::IsNullOrWhiteSpace($DistributionId)) {
    Write-Host "`n[INFO] CloudFront Distribution ID not provided. Skipping cache invalidation." -ForegroundColor DarkGray
} elseif (-not $SkipInvalidation -and (-not [string]::IsNullOrWhiteSpace($DistributionId)) -and $failCount -eq 0) {
    Write-TCBlockOpen "2. CloudFront Invalidation"
    Write-Host ""
    Write-Host "==============================================================================" -ForegroundColor Cyan
    Write-Host "CloudFront Cache Invalidation" -ForegroundColor Cyan
    Write-Host "==============================================================================" -ForegroundColor Cyan
    Write-Host "Distribution ID: $DistributionId"

    $finalPaths = if ($InvalidationPaths -and $InvalidationPaths.Count -gt 0) {
        $InvalidationPaths
    } else {
        $autoInvalidationPaths | Select-Object -Unique
    }

    if ($finalPaths.Count -eq 0) {
        $finalPaths = @("/*")
    }

    Write-Host "Invalidation Paths: $($finalPaths -join ' ')"

    $invArgs = @("cloudfront", "create-invalidation", "--distribution-id", $DistributionId, "--paths") + $finalPaths

    $invDisplay = "aws " + ($invArgs -join " ")
    if ($DryRun) {
        Write-Host "[DRY-RUN] $invDisplay" -ForegroundColor Green
        Write-Host "[SUCCESS] Cache invalidation simulated." -ForegroundColor Green
    } else {
        Write-Host "Executing: $invDisplay" -ForegroundColor Cyan
        & $AwsCliPath $invArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] CloudFront invalidation failed (Exit Code: $LASTEXITCODE)." -ForegroundColor Red
            Write-TCMessage "CloudFront invalidation failed" "ERROR"
            Write-TCBuildProblem "CloudFront invalidation failed for distribution $DistributionId"
            $failCount++
        } else {
            Write-Host "[SUCCESS] CloudFront invalidation submitted successfully." -ForegroundColor Green
        }
    }
    Write-TCBlockClose "2. CloudFront Invalidation"
}

# -------------------------------------------------------------------
# SUMMARY & EXIT
# -------------------------------------------------------------------
Write-Host ""
Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "Deployment Summary" -ForegroundColor Cyan
Write-Host "==============================================================================" -ForegroundColor Cyan
Write-Host "Successful Tasks: $successCount" -ForegroundColor Green
Write-Host "Failed Tasks:     $failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
Write-Host "==============================================================================" -ForegroundColor Cyan

if ($failCount -gt 0) {
    Write-Error "Deployment finished with $failCount error(s)."
    exit 1
} else {
    Write-Host "[SUCCESS] S3 and CloudFront deployment completed successfully." -ForegroundColor Green
    exit 0
}
