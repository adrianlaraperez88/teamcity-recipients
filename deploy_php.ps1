# PositionalBinding disabled so a malformed argument (e.g. 'RepoConfigDir' missing its leading '-')
# fails immediately instead of silently binding to the wrong parameter.
[CmdletBinding(PositionalBinding=$false)]
param(
    [Parameter(Mandatory=$false)]
    [string]$PhpMajorVersion = $env:PHP_MAJOR_VERSION,

    [Parameter(Mandatory=$false)]
    [string]$TargetPhpDir = $null,

    [Parameter(Mandatory=$false)]
    [string]$IisServiceName = "W3SVC",

    # Server on which to stop/start IIS and PHP processes. Defaults to the host of a UNC TargetPhpDir
    # (e.g. \\WEB01\c$\php\php8.3 -> WEB01), otherwise the local machine.
    [Parameter(Mandatory=$false)]
    [string]$IisComputerName = $null,

    [Parameter(Mandatory=$false)]
    [string]$RepoConfigDir = $null,

    [Parameter(Mandatory=$false)]
    [switch]$SkipIis,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun,

    # Number of copy attempts for a locked file before moving it aside
    [Parameter(Mandatory=$false)]
    [int]$LockRetryCount = 5,

    [Parameter(Mandatory=$false)]
    [int]$LockRetryDelaySeconds = 3,

    # How long to wait for PHP processes (php-cgi.exe etc.) to exit gracefully before killing them
    [Parameter(Mandatory=$false)]
    [int]$ProcessExitTimeoutSeconds = 30
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
# LOCKED FILE HANDLING
# -------------------------------------------------------------------
# Suffix for in-use files that were renamed out of the way during deployment.
$script:StaleFileMarker = ".old-deploy-"
$script:FilesMovedAside = New-Object System.Collections.Generic.List[string]

function Test-IsFileLockError([System.Exception]$ex) {
    while ($ex) {
        if ($ex -is [System.IO.IOException]) {
            # 32 = ERROR_SHARING_VIOLATION, 33 = ERROR_LOCK_VIOLATION
            $code = $ex.HResult -band 0xFFFF
            if ($code -eq 32 -or $code -eq 33) { return $true }
        }
        $ex = $ex.InnerException
    }
    return $false
}

function Copy-FileWithLockHandling([string]$Source, [string]$Destination) {
    $destDir = Split-Path $Destination -Parent
    if (!(Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

    for ($attempt = 1; $attempt -le $LockRetryCount; $attempt++) {
        try {
            [System.IO.File]::Copy($Source, $Destination, $true)
            return
        }
        catch {
            if (-not (Test-IsFileLockError $_.Exception)) { throw }
            if ($attempt -lt $LockRetryCount) {
                Write-Host "   File in use, retrying in $LockRetryDelaySeconds s ($attempt/$LockRetryCount): $Destination"
                Start-Sleep -Seconds $LockRetryDelaySeconds
            }
        }
    }

    # Still locked. Windows allows renaming a loaded DLL/EXE even though it cannot be overwritten,
    # so move the in-use file aside and place the new one at the original path. Running processes
    # keep using the old image until they restart; the stale copy is removed on the next deployment.
    $aside = "$Destination$($script:StaleFileMarker)$(Get-Date -Format 'yyyyMMddHHmmss')"
    try {
        [System.IO.File]::Move($Destination, $aside)
    }
    catch {
        throw "File '$Destination' is locked by another process and could not be moved aside: $($_.Exception.Message). Stop the processes using it (php-cgi.exe / php.exe / w3wp.exe) on the machine that hosts or loads it, then re-run."
    }

    try {
        [System.IO.File]::Copy($Source, $Destination, $true)
    }
    catch {
        # Restore the original so the installation is not left without this file
        try { [System.IO.File]::Move($aside, $Destination) } catch { }
        throw
    }

    Write-Warning "File was in use and was replaced via rename: $Destination"
    $script:FilesMovedAside.Add($Destination)
}

function Copy-DirectoryWithLockHandling([string]$SourceDir, [string]$DestinationDir, [string[]]$ExcludeTopLevel = @()) {
    $srcRoot = (Resolve-Path -LiteralPath $SourceDir).ProviderPath.TrimEnd('\')
    Get-ChildItem -LiteralPath $srcRoot -Force | Where-Object { $ExcludeTopLevel -notcontains $_.Name } | ForEach-Object {
        if ($_.PSIsContainer) {
            Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Force | ForEach-Object {
                $relative = $_.FullName.Substring($srcRoot.Length + 1)
                Copy-FileWithLockHandling $_.FullName (Join-Path $DestinationDir $relative)
            }
        } else {
            Copy-FileWithLockHandling $_.FullName (Join-Path $DestinationDir $_.Name)
        }
    }
}

function Remove-StaleDeploymentFiles([string]$Dir) {
    if (!(Test-Path -LiteralPath $Dir)) { return }
    Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -Filter "*$($script:StaleFileMarker)*" -ErrorAction SilentlyContinue | ForEach-Object {
        # Files still loaded by a running process cannot be deleted yet; they will be retried next run.
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Get-PhpProcessesInDir([string]$Dir, $CimSession = $null) {
    $root = ($Dir -replace '/', '\').TrimEnd('\') + '\'
    $cimArgs = @{ ClassName = 'Win32_Process'; Filter = "Name LIKE 'php%.exe'"; ErrorAction = 'SilentlyContinue' }
    if ($CimSession) { $cimArgs.CimSession = $CimSession }
    Get-CimInstance @cimArgs |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) }
}

function Stop-PhpProcessesInDir([string]$Dir, [int]$TimeoutSeconds, $CimSession = $null) {
    $procs = @(Get-PhpProcessesInDir $Dir $CimSession)
    if ($procs.Count -eq 0) { return }

    Write-Host "Waiting up to $TimeoutSeconds s for $($procs.Count) PHP process(es) running from $Dir to exit..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline -and @(Get-PhpProcessesInDir $Dir $CimSession).Count -gt 0) {
        Start-Sleep -Seconds 1
    }

    $remaining = @(Get-PhpProcessesInDir $Dir $CimSession)
    foreach ($p in $remaining) {
        Write-Host " -> Terminating $($p.Name) (PID $($p.ProcessId))"
        Invoke-CimMethod -InputObject $p -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
    }
    if ($remaining.Count -gt 0) { Start-Sleep -Seconds 2 }
}

function Get-ServiceController([string]$Name, [string]$Computer) {
    Add-Type -AssemblyName System.ServiceProcess -ErrorAction SilentlyContinue
    try {
        $svc = New-Object System.ServiceProcess.ServiceController($Name, $Computer)
        $null = $svc.Status   # throws if the service does not exist or is inaccessible
        return $svc
    }
    catch {
        $script:ServiceLookupError = $_.Exception.InnerException.Message
        if (-not $script:ServiceLookupError) { $script:ServiceLookupError = $_.Exception.Message }
        return $null
    }
}

# -------------------------------------------------------------------
# VALIDATION & FALLBACKS
# -------------------------------------------------------------------
$scriptName = $MyInvocation.MyCommand.Name

if ([string]::IsNullOrEmpty($PhpMajorVersion)) {
    Write-Error "PHP Major Version is required. Either set the environment variable PHP_MAJOR_VERSION or pass -PhpMajorVersion parameter (e.g. -PhpMajorVersion '8.3')."
    Write-Host ""
    Write-Host "Usage: powershell -File $scriptName [-PhpMajorVersion <version>] [-TargetPhpDir <path>] [-IisServiceName <name>] [-IisComputerName <server>] [-RepoConfigDir <path>] [-SkipIis] [-DryRun]"
    exit 1
}

if ([string]::IsNullOrEmpty($TargetPhpDir)) {
    $TargetPhpDir = "C:\PHP\PHP$PhpMajorVersion"
}
# Normalise mixed separators (e.g. \\host\c$/php/php8.3)
$TargetPhpDir = ($TargetPhpDir -replace '/', '\').TrimEnd('\')

$phpExecutable = Join-Path $TargetPhpDir "php.exe"

# Work out which machine actually runs PHP from TargetPhpDir, and the path as seen on that machine.
#   \\WEB01\c$\php\php8.3  -> host WEB01, local path C:\php\php8.3
#   \\FS01\share\php8.3    -> host FS01,  local path unknown (not an admin share)
#   C:\php\php8.3          -> local machine
$targetHost = $null
$targetHostLocalDir = $TargetPhpDir
if ($TargetPhpDir -match '^\\\\([^\\]+)\\([A-Za-z])\$(\\.*)?$') {
    $targetHost = $Matches[1]
    $targetHostLocalDir = "$($Matches[2].ToUpper()):$(if ($Matches[3]) { $Matches[3] } else { '\' })"
} elseif ($TargetPhpDir -match '^\\\\([^\\]+)\\') {
    $targetHost = $Matches[1]
    $targetHostLocalDir = $null
}
if ($targetHost -and ($targetHost -eq '.' -or $targetHost -eq 'localhost' -or $targetHost -eq $env:COMPUTERNAME)) {
    $targetHost = $null
    if (-not $targetHostLocalDir) { $targetHostLocalDir = $TargetPhpDir }
}

if ([string]::IsNullOrEmpty($IisComputerName)) {
    $IisComputerName = if ($targetHost) { $targetHost } else { '.' }
}
$iisHostLabel = if ($IisComputerName -eq '.') { 'local machine' } else { $IisComputerName }

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
$iisService = $null
$iisStoppedByScript = $false
if (-not $SkipIis) {
    $iisService = Get-ServiceController $IisServiceName $IisComputerName
    if (-not $iisService) {
        Write-Warning "IIS service '$IisServiceName' not found or not accessible on $iisHostLabel : $($script:ServiceLookupError)"
        Write-TCMessage "IIS service '$IisServiceName' not found or not accessible on $iisHostLabel." "WARNING"
    }
}
$hasIisService = [bool]$iisService

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
        # Execute php.exe with -n (no php.ini) to avoid extension warnings interfering with version check.
        # Join output lines to a single string so regex capture groups correctly populate $Matches.
        $rawVersionOutput = (& $phpExecutable -n -v 2>&1) -join "`n"
        if ($rawVersionOutput -match 'PHP\s+(\d+\.\d+\.\d+)') {
            $currentLocalVersion = $Matches[1]
        } elseif ($rawVersionOutput -match '(\d+\.\d+\.\d+)') {
            $currentLocalVersion = $Matches[1]
        }
    }
    catch {
        Write-Warning "Failed executing $phpExecutable : $($_.Exception.Message)"
    }

    # Fallback to FileVersionInfo if CLI execution failed or couldn't parse the version string
    if ($currentLocalVersion -eq "0.0.0" -or [string]::IsNullOrWhiteSpace($currentLocalVersion)) {
        try {
            $fvi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($phpExecutable)
            $fileVersion = if ($fvi.ProductVersion) { $fvi.ProductVersion } else { $fvi.FileVersion }
            if ($fileVersion -match '(\d+\.\d+\.\d+)') {
                $currentLocalVersion = $Matches[1]
            }
        }
        catch {
            # FileVersionInfo not available
        }
    }

    if ($currentLocalVersion -eq "0.0.0" -or [string]::IsNullOrWhiteSpace($currentLocalVersion)) {
        Write-Warning "Unable to determine installed PHP version."
        Write-TCMessage "Unable to determine installed PHP version." "WARNING"
        $currentLocalVersion = "0.0.0"
    }
}

$needsCoreUpdate = $false
try {
    $needsCoreUpdate = ([version]$latestPatchVersion -gt [version]$currentLocalVersion)
} catch {
    $needsCoreUpdate = $true
}
if (!(Test-Path $TargetPhpDir)) { $needsCoreUpdate = $true }
if (!(Test-Path $phpExecutable)) { $needsCoreUpdate = $true }
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
        Write-Host "[DRY-RUN] Would stop service $IisServiceName on $iisHostLabel"
    } else {
        Write-Host "[DRY-RUN] IIS service ($IisServiceName) not found on $iisHostLabel. Skipping service stop."
    }
} else {
    if ($hasIisService) {
        $iisService.Refresh()
        if ($iisService.Status -ne 'Stopped') {
            Write-Host "Stopping IIS ($IisServiceName) on $iisHostLabel..."
            try {
                $iisService.Stop()   # also stops dependent services
                $iisStoppedByScript = $true
                $iisService.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(120))
            }
            catch {
                Write-Warning "Failed to stop IIS ($IisServiceName) on $iisHostLabel : $($_.Exception.Message)"
                Write-TCMessage "Failed to stop IIS ($IisServiceName) on $iisHostLabel : $($_.Exception.Message)" "WARNING"
            }
        } else {
            Write-Host "IIS ($IisServiceName) on $iisHostLabel is already stopped."
        }
    } else {
        Write-Host "IIS service ($IisServiceName) is not installed or skipped on $iisHostLabel. Skipping service stop."
    }
}

# Stopping IIS does not wait for FastCGI workers (php-cgi.exe) to exit, and other PHP processes may
# also hold the binaries open. Stop them on the machine that runs PHP from TargetPhpDir.
$phpCimSession = $null
$canManagePhpProcesses = $true
if ($targetHost) {
    if (-not $targetHostLocalDir) {
        $canManagePhpProcesses = $false
        Write-Warning "Cannot map $TargetPhpDir to a local path on $targetHost (not an admin share like \\host\c$). Remote PHP processes will not be stopped."
    } else {
        try {
            # DCOM works wherever admin shares do and does not require WinRM
            $phpCimSession = New-CimSession -ComputerName $targetHost -SessionOption (New-CimSessionOption -Protocol Dcom) -ErrorAction Stop
        }
        catch {
            $canManagePhpProcesses = $false
            Write-Warning "Unable to connect to $targetHost to manage PHP processes: $($_.Exception.Message)"
        }
    }
}

if ($canManagePhpProcesses) {
    if ($DryRun) {
        $phpProcs = @(Get-PhpProcessesInDir $targetHostLocalDir $phpCimSession)
        if ($phpProcs.Count -gt 0) {
            Write-Host "[DRY-RUN] Would stop $($phpProcs.Count) PHP process(es) running from $targetHostLocalDir on $iisHostLabel"
        }
    } else {
        Stop-PhpProcessesInDir $targetHostLocalDir $ProcessExitTimeoutSeconds $phpCimSession
    }
} else {
    Write-Warning "PHP processes using $TargetPhpDir could not be stopped; locked files will be replaced via rename and the server must recycle IIS to load the new binaries."
    Write-TCMessage "PHP processes using $TargetPhpDir could not be stopped from this agent." "WARNING"
}
if ($phpCimSession) { Remove-CimSession $phpCimSession -ErrorAction SilentlyContinue }

try {
    if ($DryRun) {
        Write-Host "[DRY-RUN] Would create directory (if missing): $TargetPhpDir"
        Write-Host "[DRY-RUN] Would create directory (if missing): $(Join-Path $TargetPhpDir 'ext')"
    } else {
        if (!(Test-Path $TargetPhpDir)) { New-Item -ItemType Directory -Path $TargetPhpDir -Force | Out-Null }
        if (!(Test-Path (Join-Path $TargetPhpDir "ext"))) { New-Item -ItemType Directory -Path (Join-Path $TargetPhpDir "ext") -Force | Out-Null }
        Remove-StaleDeploymentFiles $TargetPhpDir
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
            Copy-DirectoryWithLockHandling $tempExtractPath $TargetPhpDir @("php.ini", "ext")

            Write-Host "Deploying official extensions..."
            Copy-DirectoryWithLockHandling (Join-Path $tempExtractPath "ext") (Join-Path $TargetPhpDir "ext")
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
            Copy-FileWithLockHandling $repoIniFile (Join-Path $TargetPhpDir "php.ini")
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
                Copy-FileWithLockHandling $_.FullName (Join-Path (Join-Path $TargetPhpDir "ext") $_.Name)
                Write-Host " -> $($_.Name)"
            }
        }
    }

    Write-Host ""
    if ($DryRun) {
        Write-Host "[DRY-RUN] Deployment simulation completed successfully."
    } else {
        if ($script:FilesMovedAside.Count -gt 0) {
            $msg = "$($script:FilesMovedAside.Count) file(s) were in use and replaced via rename. Processes still using the old binaries must be restarted (recycle IIS / app pools on every server using $TargetPhpDir)."
            Write-Warning $msg
            Write-TCMessage $msg "WARNING"
        }
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
            Write-Host "[DRY-RUN] Would start service $IisServiceName on $iisHostLabel"
        }
    } else {
        if ($iisStoppedByScript) {
            Write-Host "Starting IIS ($IisServiceName) on $iisHostLabel..."
            try {
                $iisService.Start()
                $iisService.WaitForStatus('Running', [TimeSpan]::FromSeconds(120))
            }
            catch {
                Write-TCBuildProblem "Failed to restart IIS ($IisServiceName) on $iisHostLabel : $($_.Exception.Message)"
                Write-Error "Failed to restart IIS ($IisServiceName) on $iisHostLabel : $($_.Exception.Message)"
            }
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
        try {
            $verifyOutput = (& $phpExecutable -v 2>&1) -join "`n"
            Write-Host $verifyOutput
        }
        catch {
            Write-Warning "Unable to execute PHP for version verification: $($_.Exception.Message)"
            Write-TCMessage "Unable to execute PHP for version verification: $($_.Exception.Message)" "WARNING"
        }
    } else {
        Write-Warning "PHP executable not found at $phpExecutable."
        Write-TCMessage "PHP executable not found at $phpExecutable." "WARNING"
    }
}
Write-TCBlockClose "5. Verify Installation"
