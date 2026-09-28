[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$PhpMajorVersion = $env:PHP_MAJOR_VERSION,

    [Parameter(Mandatory=$false)]
    [string]$TargetPhpDir = $null,

    [Parameter(Mandatory=$false)]
    [string]$IisServiceName = "W3SVC",

    [Parameter(Mandatory=$false)]
    [string]$RepoConfigDir = $null,

    [Parameter(Mandatory=$false)]
    [switch]$SkipIis,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun
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
# VALIDATION & FALLBACKS
# -------------------------------------------------------------------
$scriptName = $MyInvocation.MyCommand.Name

if ([string]::IsNullOrEmpty($PhpMajorVersion)) {
    Write-Error "PHP Major Version is required. Either set the environment variable PHP_MAJOR_VERSION or pass -PhpMajorVersion parameter (e.g. -PhpMajorVersion '8.3')."
    Write-Host ""
    Write-Host "Usage: powershell -File $scriptName [-PhpMajorVersion <version>] [-TargetPhpDir <path>] [-IisServiceName <name>] [-RepoConfigDir <path>] [-SkipIis] [-DryRun]"
    exit 1
}

if ([string]::IsNullOrEmpty($TargetPhpDir)) {
    $TargetPhpDir = "C:\PHP\PHP$PhpMajorVersion"
}

$phpExecutable = Join-Path $TargetPhpDir "php.exe"

if ([string]::IsNullOrEmpty($RepoConfigDir)) {
    $hasTeamCityDir = [System.Environment]::GetEnvironmentVariable("TEAMCITY_BUILD_CHECKOUTDIR")
    if ($hasTeamCityDir) {
        $RepoConfigDir = Join-Path $env:TEAMCITY_BUILD_CHECKOUTDIR "php-config"
    } else {
        $RepoConfigDir = Join-Path $PSScriptRoot "php-config"
    }
}

$repoIniFile = Join-Path $RepoConfigDir "php.ini"
$repoExtDir  = Join-Path $RepoConfigDir "ext"

# Determine if we should check and manage the IIS service
$hasIisService = $false
if (-not $SkipIis) {
    $hasIisService = Get-Service -Name $IisServiceName -ErrorAction SilentlyContinue
}

# Official Windows PHP release API
$apiUrl = "https://windows.php.net/downloads/releases/releases.json"

# Use TLS 1.2 on older PowerShell versions
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -------------------------------------------------------------------
# 1. CHECK REMOTE VERSION
# -------------------------------------------------------------------
Write-TCBlockOpen "1. Check Remote Version"
Write-Host "Checking windows.php.net for latest PHP $PhpMajorVersion release..."
try {
    $releases = Invoke-RestMethod -Uri $apiUrl

    # Escape the variable value to safely use it dynamically in a regex pattern
    $escapedVersion = [regex]::Escape($PhpMajorVersion)
    # If the user supplied major.minor (e.g. 8.3), match it exactly. If they supplied major (e.g. 8), match major.minor (e.g. 8.x)
    $pattern = if ($PhpMajorVersion -match '^\d+$') { "^$escapedVersion\.\d+$" } else { "^$escapedVersion$" }

    $matchedKey = $releases.PSObject.Properties.Name |
        Where-Object { $_ -match $pattern } |
        Sort-Object { [version]$_ } -Descending |
        Select-Object -First 1

    if (-not $matchedKey) {
        throw "No PHP $PhpMajorVersion releases found."
    }

    $releaseData = $releases.$matchedKey
    $latestPatchVersion = $releaseData.version

    # Find the property for non-thread-safe x64 zip dynamically
    $ntsPropName = $releaseData.PSObject.Properties.Name |
        Where-Object { $_ -like "nts-*-x64" } |
        Select-Object -First 1

    if (-not $ntsPropName) {
        throw "No NTS x64 build available for PHP $latestPatchVersion."
    }

    $ntsBuild = $releaseData.$ntsPropName
    $zipPath = $ntsBuild.zip.path
    if (-not $zipPath) {
        throw "No zip path found in NTS x64 build."
    }

    # If the zip path is relative, prefix it with the standard downloads path
    if ($zipPath -notlike "/downloads/releases/*") {
        $zipPath = "/downloads/releases/$zipPath"
    }

    $downloadUrl = "https://windows.php.net$zipPath"
    Write-Host "Latest available version: $latestPatchVersion"
}
catch {
    Write-TCMessage "Failed to retrieve PHP release information: $($_.Exception.Message)" "ERROR"
    Write-TCBuildProblem "Failed to retrieve PHP release information: $($_.Exception.Message)"
    Write-Error "Failed to retrieve PHP release information."
    Write-Error $_.Exception.Message
    Write-TCBlockClose "1. Check Remote Version"
    exit 1
}
Write-TCBlockClose "1. Check Remote Version"

# -------------------------------------------------------------------
# 2. DETERMINE IF UPDATE IS REQUIRED
# -------------------------------------------------------------------
Write-TCBlockOpen "2. Determine If Update Required"
$currentLocalVersion = "0.0.0"
if (Test-Path $phpExecutable) {
    try {
        $phpVersionOutput = & $phpExecutable -v
        if ($phpVersionOutput -match 'PHP\s+(\d+\.\d+\.\d+)') {
            $currentLocalVersion = $Matches[1]
        }
    }
    catch {
        Write-Warning "Unable to determine installed PHP version."
        Write-TCMessage "Unable to determine installed PHP version." "WARNING"
    }
}

$needsCoreUpdate = ([version]$latestPatchVersion -gt [version]$currentLocalVersion)
if (!(Test-Path $TargetPhpDir)) { $needsCoreUpdate = $true }
if (!(Test-Path (Join-Path $TargetPhpDir "php.ini"))) { $needsCoreUpdate = $true }

if ($needsCoreUpdate) {
    Write-Host ""
    Write-Host "Core upgrade required."
    Write-Host "Installed : $currentLocalVersion"
    Write-Host "Available : $latestPatchVersion"
} else {
    Write-Host ""
    Write-Host "PHP is already up to date ($currentLocalVersion)."
    Write-Host "Only configuration files will be synchronized."
}
Write-TCBlockClose "2. Determine If Update Required"

# -------------------------------------------------------------------
# 3. DOWNLOAD & EXTRACT (IF REQUIRED)
# -------------------------------------------------------------------
Write-TCBlockOpen "3. Download and Extract Core"
$tempZipPath = Join-Path $env:TEMP "php-$latestPatchVersion.zip"
$tempExtractPath = Join-Path $env:TEMP "php_extract_tmp"

if ($needsCoreUpdate) {
    if ($DryRun) {
        Write-Host ""
        Write-Host "[DRY-RUN] Would download PHP from $downloadUrl to $tempZipPath"
        Write-Host "[DRY-RUN] Would extract archive to $tempExtractPath"
    } else {
        if (Test-Path $tempExtractPath) { Remove-Item $tempExtractPath -Recurse -Force }

        Write-Host ""
        Write-Host "Downloading PHP $latestPatchVersion..."
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZipPath

        Write-Host "Extracting archive..."
        Expand-Archive -Path $tempZipPath -DestinationPath $tempExtractPath -Force
        Remove-Item $tempZipPath -Force
    }
} else {
    Write-Host "Skipping download, PHP core is up to date."
}
Write-TCBlockClose "3. Download and Extract Core"

# -------------------------------------------------------------------
# 4. DEPLOY
# -------------------------------------------------------------------
Write-TCBlockOpen "4. Deploy Binaries and Configuration"
Write-Host ""
if ($DryRun) {
    if ($SkipIis) {
        Write-Host "[DRY-RUN] IIS service management skipped via -SkipIis."
    } elseif ($hasIisService) {
        Write-Host "[DRY-RUN] Would stop service $IisServiceName"
    } else {
        Write-Host "[DRY-RUN] IIS service ($IisServiceName) not found. Skipping service stop."
    }
} else {
    if ($hasIisService) {
        Write-Host "Stopping IIS..."
        Stop-Service -Name $IisServiceName -Force
    } else {
        Write-Host "IIS service ($IisServiceName) is not installed or skipped. Skipping service stop."
    }
}

try {
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would create directory (if missing): $TargetPhpDir"
        Write-Host "[DRY-RUN] Would create directory (if missing): $(Join-Path $TargetPhpDir 'ext')"
    } else {
        if (!(Test-Path $TargetPhpDir)) { New-Item -ItemType Directory -Path $TargetPhpDir -Force | Out-Null }
        if (!(Test-Path (Join-Path $TargetPhpDir "ext"))) { New-Item -ItemType Directory -Path (Join-Path $TargetPhpDir "ext") -Force | Out-Null }
    }

    # ---------------------------------------------------------------
    # Deploy Core PHP
    # ---------------------------------------------------------------
    if ($needsCoreUpdate) {
        Write-Host ""
        if ($DryRun) {
            Write-Host "[DRY-RUN] Would copy core PHP files from extracted archive to $TargetPhpDir"
            Write-Host "[DRY-RUN] Would copy official extension files to $(Join-Path $TargetPhpDir 'ext')"
        } else {
            Write-Host "Deploying PHP binaries..."
            Get-ChildItem $tempExtractPath | Where-Object { $_.Name -ne "php.ini" -and $_.Name -ne "ext" } | ForEach-Object {
                Copy-Item $_.FullName $TargetPhpDir -Recurse -Force
            }

            Write-Host "Deploying official extensions..."
            Get-ChildItem (Join-Path $tempExtractPath "ext") | ForEach-Object {
                Copy-Item $_.FullName (Join-Path $TargetPhpDir "ext") -Force
            }
        }
    }

    # ---------------------------------------------------------------
    # Deploy php.ini
    # ---------------------------------------------------------------
    if (Test-Path $repoIniFile) {
        Write-Host ""
        if ($DryRun) {
            Write-Host "[DRY-RUN] Would copy php.ini from $repoIniFile to $(Join-Path $TargetPhpDir 'php.ini')"
        } else {
            Write-Host "Deploying repository php.ini..."
            Copy-Item `
                -Path $repoIniFile `
                -Destination (Join-Path $TargetPhpDir "php.ini") `
                -Force
        }
    } else {
        Write-Warning "Repository php.ini not found at $repoIniFile."
        Write-TCMessage "Repository php.ini not found at $repoIniFile." "WARNING"
    }

    # ---------------------------------------------------------------
    # Deploy Custom Extensions
    # ---------------------------------------------------------------
    if (Test-Path $repoExtDir) {
        Write-Host ""
        if ($DryRun) {
            Write-Host "[DRY-RUN] Would copy custom extensions from $repoExtDir to $(Join-Path $TargetPhpDir 'ext'):"
            Get-ChildItem $repoExtDir -Filter "*.dll" | ForEach-Object {
                Write-Host " -> [DRY-RUN] Would copy $($_.Name)"
            }
        } else {
            Write-Host "Deploying custom extensions..."
            Get-ChildItem $repoExtDir -Filter "*.dll" | ForEach-Object {
                Copy-Item `
                    $_.FullName `
                    (Join-Path $TargetPhpDir "ext") `
                    -Force
                Write-Host " -> $($_.Name)"
            }
        }
    }

    Write-Host ""
    if ($DryRun) {
        Write-Host "[DRY-RUN] Deployment simulation completed successfully."
    } else {
        Write-Host "Deployment completed successfully."
    }
}
catch {
    Write-TCMessage "Deployment failed: $($_.Exception.Message)" "ERROR"
    Write-TCBuildProblem "PHP Deployment failed: $($_.Exception.Message)"
    Write-Error "Deployment failed."
    throw
}
finally {
    Write-Host ""
    if ($DryRun) {
        if ($SkipIis) {
            Write-Host "[DRY-RUN] IIS service management skipped via -SkipIis."
        } elseif ($hasIisService) {
            Write-Host "[DRY-RUN] Would start service $IisServiceName"
        }
    } else {
        if ($hasIisService) {
            Write-Host "Starting IIS..."
            Start-Service -Name $IisServiceName
        }
        if (Test-Path $tempExtractPath) { Remove-Item $tempExtractPath -Recurse -Force }
    }
    Write-TCBlockClose "4. Deploy Binaries and Configuration"
}

# -------------------------------------------------------------------
# 5. VERIFY INSTALLATION
# -------------------------------------------------------------------
Write-TCBlockOpen "5. Verify Installation"
Write-Host ""
if ($DryRun) {
    Write-Host "[DRY-RUN] Would verify installed PHP version by running: $phpExecutable -v"
} else {
    Write-Host "Installed PHP version:"
    if (Test-Path $phpExecutable) {
        & $phpExecutable -v
    } else {
        Write-Warning "PHP executable not found at $phpExecutable."
        Write-TCMessage "PHP executable not found at $phpExecutable." "WARNING"
    }
}
Write-TCBlockClose "5. Verify Installation"
