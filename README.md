# TeamCity Deployment and PHP Update Scripts

A repository of robust, modular, and highly configurable deployment and synchronization scripts designed for Windows servers and Cloud infrastructure (AWS S3 & CloudFront). These scripts are tailored for automated pipelines (like TeamCity build steps) but are also fully compatible with local, manual executions.

---

## Table of Contents
1. [Overview of Scripts](#overview-of-scripts)
2. [Server Connection Modules](#1-server-connection-modules)
   - [connect_recipients.bat](#connect_recipientsbat)
   - [disconnect_recipients.bat](#disconnect_recipientsbat)
3. [Windows Deployment Modules](#2-windows-deployment-modules)
   - [copy_recipients.bat](#copy_recipientsbat)
   - [deploy_robocopy_recipients.bat](#deploy_robocopy_recipientsbat)
4. [AWS S3 & CloudFront Deployment Module](#3-aws-s3--cloudfront-deployment-module)
   - [deploy_s3_cloudfront.bat & deploy_s3_cloudfront.ps1](#deploy_s3_cloudfrontbat--deploy_s3_cloudfrontps1)
5. [Examples: How to Use All Deployment Modules Together](#5-examples-how-to-use-all-deployment-modules-together)
   - [Scenario A: Hybrid On-Premises & Cloud Deployment](#scenario-a-hybrid-on-premises--cloud-deployment-same-recipient-list)
   - [Scenario B: Full Master Orchestration Script (PowerShell)](#scenario-b-full-master-orchestration-script-powershell)
   - [Scenario C: TeamCity Multi-Target Pipeline](#scenario-c-teamcity-multi-target-pipeline)
6. [PHP Auto-Update & Configuration](#6-php-auto-update--configuration)
   - [deploy_php.ps1](#deploy_phpps1)
7. [TeamCity Quick Start Guide](#teamcity-quick-start-guide)
8. [Remote PHP Update on Server "X" Example](#remote-php-update-on-server-x-example)
9. [Sharing with the Community](#sharing-with-the-community)
   - [Directory Structure](#1-directory-structure)
   - [Versioned Settings (Kotlin DSL)](#2-versioned-settings-kotlin-dsl)
10. [Testing](#testing)

---

## Overview of Scripts

| Script Name | Language | Purpose | Reusable? |
| :--- | :--- | :--- | :--- |
| `connect_recipients.bat` | Windows Batch | Authenticates and mounts remote server share (`net use`). | Yes |
| `disconnect_recipients.bat` | Windows Batch | Unmounts/cleans up remote server connection. | Yes |
| `copy_recipients.bat` | Windows Batch | Deploys files for multiple recipients to server folders. | Yes |
| `deploy_robocopy_recipients.bat` | Windows Batch | Fast folder mirroring using `robocopy` (e.g. `ISGOEV2`). | Yes |
| `deploy_s3_cloudfront.bat` | Windows Batch | Batch wrapper for AWS S3 sync & CloudFront invalidation. | Yes |
| `deploy_s3_cloudfront.ps1` | PowerShell | Core engine for AWS S3 sync & CloudFront cache invalidation. | Yes |
| `deploy_php.ps1` | PowerShell | Downloads PHP core, deploys config files & extensions. | Yes |

---

## 1. Server Connection Modules

### `connect_recipients.bat`
Authenticates and mounts the network share directory.
* **Usage**: `connect_recipients.bat [options]`
* **Parameters**:
  - `--server <UNC_path>`: The target server path (e.g. `\\my-server\share`). Falls back to `%DEPLOY_SERVER%`.
  - `--user <username>`: The user login name. Falls back to `%user%`.
  - `--domain <domain>`: Optional Active Directory domain. Falls back to `%USER_DOMAIN%` or `%DOMAIN%`.
  - `--password <pwd>`: The password. Falls back to `%password%`.
  - `--dry-run` or `/dryrun`: Simulation mode (logs actions without executing).

---

### `disconnect_recipients.bat`
Unmounts and disconnects the network share.
* **Usage**: `disconnect_recipients.bat [options]`
* **Parameters**:
  - `--server <UNC_path>`: Target server path to disconnect. Falls back to `%DEPLOY_SERVER%`.
  - `--dry-run` or `/dryrun`: Simulation mode.

---

## 2. Windows Deployment Modules

### `copy_recipients.bat`
Iterates through a list of folders (recipients) and copies their files to the target server after clearing existing directories.
* **Usage**: `copy_recipients.bat [options] [recipient1 [recipient2 ...]]`
* **Parameters**:
  - `--server <UNC_path>`: Target server path. Falls back to `%DEPLOY_SERVER%`.
  - `--user <username>`: Login username. Falls back to `%user%`.
  - `--domain <domain>`: Optional domain name. Falls back to `%USER_DOMAIN%` or `%DOMAIN%`.
  - `--password <pwd>`: Login password. Falls back to `%password%`.
  - `--recipients "list"`: Space-separated list of folders (e.g. `"recipient1 partner1 partner2"`). Falls back to `%RECIPIENT_LIST%`.
  - `--dry-run` or `/dryrun`: Simulation mode.
* **Flow**:
  1. Calls `connect_recipients.bat` to mount connection.
  2. Loops through recipient list. If the source folder exists locally, it deletes the remote recipient directory and runs `xcopy /Y /I /E` to deploy.
  3. Calls `disconnect_recipients.bat` to unmount.

---

### `deploy_robocopy_recipients.bat`
Synchronizes a local source folder with a remote directory using `robocopy` mirror capabilities.
* **Usage**: `deploy_robocopy_recipients.bat [options]`
* **Parameters**:
  - `--server <UNC_path>`: Target server. Falls back to `%DEPLOY_SERVER%`.
  - `--user <username>`: Username. Falls back to `%user%`.
  - `--domain <domain>`: Optional domain name. Falls back to `%USER_DOMAIN%` or `%DOMAIN%`.
  - `--password <pwd>`: Password. Falls back to `%password%`.
  - `--source <path>`: Local source directory (default: `.`).
  - `--target-subfolder <name>`: Target directory on the server (default: `%TARGET_SUBFOLDER%` or `shared`).
  - `--dry-run` or `/dryrun`: Simulation mode.
* **Flow**:
  1. Calls `connect_recipients.bat` to mount connection.
  2. Runs `robocopy <source> <target> /MIR /FFT /Z /R:5 /W:60 /MT:16 /LOG:robocopy_log.txt /XF exclude.txt`.
  3. Calls `disconnect_recipients.bat` to unmount.
  4. Parses Robocopy exit code: exit code `>= 8` is reported as copy failure, while exit code `< 8` is handled as success.

---

## 4. AWS S3 & CloudFront Deployment Module

### `deploy_s3_cloudfront.bat` & `deploy_s3_cloudfront.ps1`
Synchronizes project build artifacts or multi-recipient directory trees directly to **Amazon S3** (`aws s3 sync`) and creates cache invalidations on **Amazon CloudFront** (`aws cloudfront create-invalidation`). Emits native TeamCity service messages (`##teamcity[...]`) for pipeline monitoring.

* **Dual-Mode Operation**:
  - **Multi-Recipient Mode**: When a recipient list is supplied (via positional arguments, `-Recipients`, or `%RECIPIENT_LIST%`), each recipient directory is synced to `s3://<bucket>/[prefix]/<recipient>/` and invalidates `/[prefix]/<recipient>/*`.
  - **Single Source Folder Mode**: When no recipient list is provided, synchronizes the `-SourcePath` folder (e.g. `.` or `dist`) to `s3://<bucket>/[prefix]` and invalidates `/[prefix]/*`.

* **PowerShell Usage**:
  ```powershell
  powershell.exe -ExecutionPolicy Bypass -File deploy_s3_cloudfront.ps1 `
    -Bucket "my-production-bucket" `
    -DistributionId "E12345EXAMPLE" `
    -Region "us-east-1" `
    -S3Prefix "apps/project1" `
    -Recipients "rec1 rec2" `
    -Delete `
    -DryRun
  ```

* **Batch Wrapper Usage**:
  ```cmd
  cmd.exe /c deploy_s3_cloudfront.bat --bucket my-production-bucket --distribution-id E12345EXAMPLE --region us-east-1 --prefix apps/project1 --delete rec1 rec2
  ```

* **Parameters & Environment Variable Fallbacks**:
  | CLI Parameter | Batch Flag | Env Variable Fallback | Description |
  | :--- | :--- | :--- | :--- |
  | `-Bucket` | `--bucket` | `AWS_S3_BUCKET` / `S3_BUCKET` | Target AWS S3 Bucket (Required). |
  | `-DistributionId` | `--distribution-id` | `CLOUDFRONT_DISTRIBUTION_ID` / `CLOUDFRONT_ID` | CloudFront Distribution ID for cache invalidation. |
  | `-Region` | `--region` | `AWS_REGION` / `AWS_DEFAULT_REGION` | AWS Region (Default: `us-east-1`). |
  | `-S3Prefix` | `--prefix` | `S3_PREFIX` | S3 prefix/subpath (e.g. `apps/project`). |
  | `-Recipients` | `[args]` / `--recipients` | `RECIPIENT_LIST` | Space/comma separated recipient folders. |
  | `-SourcePath` | `--source` | `SOURCE_DIR` | Local directory to deploy in single-source mode (Default: `.`). |
  | `-Delete` | `--delete` | N/A | Deletes remote files not present in local source (`aws s3 sync --delete`). |
  | `-SkipInvalidation`| `--skip-invalidation`| N/A | Bypasses CloudFront cache invalidation. |
  | `-InvalidationPaths`| `--invalidation-paths`| `INVALIDATION_PATHS` | Custom paths to invalidate (e.g. `/*` or `/index.html`). |
  | `-DryRun` | `--dry-run` / `/dryrun` | N/A | Preview commands without executing AWS CLI changes. |

* **AWS Authentication Prerequisites**:
  Ensure AWS CLI is installed on the agent/machine and configured via either:
  - AWS IAM Instance Profile / Role on the build agent, or
  - Standard AWS environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`), or
  - TeamCity AWS Credentials build feature.

## 5. Examples: How to Use All Deployment Modules Together

In real-world delivery pipelines, projects often need to publish assets to **multiple destinations simultaneously**: on-premise Windows IIS servers (via SMB network shares), dedicated shared storage (via Robocopy), and Cloud infrastructure (AWS S3 & CloudFront CDN).

Below are concrete examples illustrating how to orchestrate all deployment modules together.

---

### Scenario A: Hybrid On-Premises & Cloud Deployment (Same Recipient List)
When deploying a multi-tenant application where backend recipient directories go to a Windows server and frontend web assets go to AWS S3 / CloudFront:

```cmd
:: 1. Define shared deployment parameters
set DEPLOY_SERVER=\\PROD-SERVER-01\inetpub\recipients
set user=deploy_svc
set USER_DOMAIN=CORP
set password=%password%
set RECIPIENT_LIST=partner1 partner2 partner3

:: 2. Deploy backend service files to Windows network share
echo [STEP 1] Deploying backend recipient folders to Windows Server...
call copy_recipients.bat

:: 3. Deploy frontend assets to AWS S3 bucket and invalidate CloudFront
echo [STEP 2] Deploying frontend static files to AWS S3 and CloudFront...
call deploy_s3_cloudfront.bat --bucket my-company-web-assets --distribution-id E12345EXAMPLE --prefix portal --delete %RECIPIENT_LIST%

:: Result:
:: - Windows Server: \\PROD-SERVER-01\inetpub\recipients\partner1\, \partner2\, \partner3\
:: - AWS S3:         s3://my-company-web-assets/portal/partner1/, /partner2/, /partner3/
:: - CloudFront:     Invalidates /portal/partner1/*, /portal/partner2/*, /portal/partner3/*
```

---

### Scenario B: Full Master Orchestration Script (PowerShell)
You can orchestrate all modules in a single master script with dry-run previewing:

```powershell
param(
    [switch]$DryRun
)

$dryRunFlag = if ($DryRun) { "-DryRun" } else { "" }
$dryRunBat  = if ($DryRun) { "--dry-run" } else { "" }

Write-Host "=== 1. Running Test Suite Gate ===" -ForegroundColor Cyan
powershell.exe -ExecutionPolicy Bypass -File tests/run_tests.ps1
if ($LASTEXITCODE -ne 0) { throw "Tests failed. Aborting deployment." }

Write-Host "=== 2. Deploying Recipient Folders to Windows Server ===" -ForegroundColor Cyan
cmd.exe /c "copy_recipients.bat --server \\PROD-SERVER-01\share --user deploy_user --domain CORP --password %password% $dryRunBat client1 client2"

Write-Host "=== 3. Mirroring Shared Assets via Robocopy ===" -ForegroundColor Cyan
cmd.exe /c "deploy_robocopy_recipients.bat --server \\PROD-SERVER-01\share --target-subfolder SHARED_CORE $dryRunBat"

Write-Host "=== 4. Deploying to AWS S3 & Invalidating CloudFront ===" -ForegroundColor Cyan
powershell.exe -ExecutionPolicy Bypass -File deploy_s3_cloudfront.ps1 `
    -Bucket "my-app-production-bucket" `
    -DistributionId "E12345EXAMPLE" `
    -Region "us-east-1" `
    -S3Prefix "releases/v2" `
    -Recipients "client1 client2" `
    -Delete `
    $dryRunFlag

Write-Host "=== 5. Updating PHP Core (if required) ===" -ForegroundColor Cyan
powershell.exe -ExecutionPolicy Bypass -File deploy_php.ps1 `
    -PhpMajorVersion "8.3" `
    -SkipIis `
    $dryRunFlag

Write-Host "=== ALL DEPLOYMENTS COMPLETED SUCCESSFULLY ===" -ForegroundColor Green
```

---

### Scenario C: TeamCity Multi-Target Pipeline
In TeamCity, you can combine these steps inside a single build configuration or link them via snapshot dependencies:

| Build Step | Runner | Command / Script | What it Accomplishes |
| :--- | :--- | :--- | :--- |
| **Step 1: Test Gate** | PowerShell | `powershell.exe -ExecutionPolicy Bypass -File tests/run_tests.ps1` | Verifies parameters & scripts in dry-run before live changes. |
| **Step 2: Windows Recipients** | Command Line | `cmd.exe /c copy_recipients.bat` | Cleans remote directories & syncs `%%RECIPIENT_LIST%%` to `%%DEPLOY_SERVER%%`. |
| **Step 3: Shared Robocopy** | Command Line | `cmd.exe /c deploy_robocopy_recipients.bat` | Fast multi-threaded mirror of shared binaries/assets (`/MIR /MT:16`). |
| **Step 4: AWS Cloud Delivery** | PowerShell | `deploy_s3_cloudfront.ps1 -Bucket %env.AWS_S3_BUCKET% -DistributionId %env.CLOUDFRONT_DISTRIBUTION_ID% -Recipients %env.RECIPIENT_LIST% -Delete` | Syncs each recipient folder to AWS S3 & creates CloudFront cache invalidations. |
| **Step 5: PHP Engine** | PowerShell | `deploy_php.ps1 -PhpMajorVersion %PHP_MAJOR_VERSION%` | Dynamically downloads and updates PHP runtime & configurations. |

---

## 6. PHP Auto-Update & Configuration

### `deploy_php.ps1`
Queries the official releases catalog at `windows.php.net`, checks version diffs, downloads the latest NTS x64 binary, stops IIS, deploys core files, and synchronizes custom config files/extensions.
* **Usage**: `powershell -File deploy_php.ps1 [options]`
* **Parameters**:
  - `-PhpMajorVersion <version>`: The target major version (e.g. `"8.3"`, `"8.5"`, or `"8"`). Falls back to `$env:PHP_MAJOR_VERSION`.
  - `-TargetPhpDir <path>`: Target directory on system (default: `"C:\PHP\PHP<version>"`).
  - `-IisServiceName <name>`: IIS service name (default: `"W3SVC"`).
  - `-RepoConfigDir <path>`: Repository configuration folder containing custom `php.ini` or custom extensions directory `ext/`. Falls back to `$env:TEAMCITY_BUILD_CHECKOUTDIR\php-config` or local `.\php-config`.
  - `-SkipIis`: Completely bypasses IIS service status checks, stopping, and starting (useful for standalone environments).
  - `-DryRun`: Simulation mode.

---

## 7. TeamCity Quick Start Guide

Follow these steps to manually configure your deployment steps and variables inside TeamCity.

### 1. Define Environment Parameters
In your build configuration under **Parameters**, define the relevant variables:
* `DEPLOY_SERVER` (Configuration Parameter): Target server network path, e.g. `\\PROD-SERVER-01\share`.
* `user` (Configuration Parameter): Active directory or local username (e.g., `deploy_user`).
* `USER_DOMAIN` (Configuration Parameter): Optional domain name (e.g. `CORP`).
* `password` (Password Parameter): User password (securely masked/hidden).
* `RECIPIENT_LIST` (Configuration Parameter): Space-separated list of directories to copy, e.g. `partner1 partner2`.
* `AWS_S3_BUCKET` (Configuration Parameter): Amazon S3 bucket name (e.g. `my-app-production-bucket`).
* `CLOUDFRONT_DISTRIBUTION_ID` (Configuration Parameter): CloudFront Distribution ID (e.g. `E12345EXAMPLE`).
* `AWS_REGION` (Configuration Parameter): AWS Region (e.g. `us-east-1`).
* `PHP_MAJOR_VERSION` (Configuration Parameter): The version of PHP to deploy, e.g. `8.3`.

### 2. Configure Build Steps
Add these runners to your pipeline:

#### **Step 1: Run Local Tests (Powershell Step)**
Run the automated test runner to verify script integrity before deployment:
* **Script**: `File Path` $\rightarrow$ `tests/run_tests.ps1`

#### **Step 2: Deploy Recipient Folders (Command Line Step)**
* **Custom Script**:
  ```cmd
  cmd.exe /c copy_recipients.bat
  ```

#### **Step 3: Robocopy Mirror (Command Line Step)**
* **Custom Script**:
  ```cmd
  cmd.exe /c deploy_robocopy_recipients.bat
  ```

#### **Step 4: Deploy to AWS S3 & CloudFront (Powershell Step)**
* **Script**: `File Path` $\rightarrow$ `deploy_s3_cloudfront.ps1`
* **Script Arguments**:
  ```
  -Bucket "%env.AWS_S3_BUCKET%" -DistributionId "%env.CLOUDFRONT_DISTRIBUTION_ID%" -Region "%env.AWS_REGION%" -S3Prefix "%env.S3_PREFIX%"
  ```

#### **Step 5: Update PHP Core and Configs (Powershell Step)**
* **Script**: `File Path` $\rightarrow$ `deploy_php.ps1`
* **Script Arguments**:
  ```
  -PhpMajorVersion "%PHP_MAJOR_VERSION%" -TargetPhpDir "C:\PHP\PHP%PHP_MAJOR_VERSION%"
  ```

---

## 8. Remote PHP Update on Target Server Example

There are two primary patterns to handle PHP updates on a remote production server (e.g. `PROD-SERVER-01`):

### Pattern A: Agent-Based Update (Recommended)
This approach is used when a TeamCity Build Agent is running locally on the target Web/PHP server (`PROD-SERVER-01`).
1. Configure your TeamCity build step to target only agents running on `PROD-SERVER-01` (e.g., using **Agent Requirements** like `system.agent.name equals PROD_AGENT`).
2. The agent pulls the repository code locally.
3. The PowerShell execution runs directly on `PROD-SERVER-01`:
   ```powershell
   powershell.exe -ExecutionPolicy Bypass -File deploy_php.ps1 -PhpMajorVersion "8.3" -TargetPhpDir "C:\PHP\PHP8.3"
   ```
   *Note: Because it runs locally under the agent, it can stop IIS (`W3SVC`), overwrite `C:\PHP\PHP8.3`, apply configurations, and start IIS safely.*

### Pattern B: Remote PowerShell Execution (WinRM/PSRemoting)
If the TeamCity Agent runs on a central build server and must trigger the PHP update remotely on Server `PROD-SERVER-01`:
1. Ensure WinRM (PowerShell Remoting) is enabled on `PROD-SERVER-01`.
2. Add a **PowerShell** build step in TeamCity on the central Agent.
3. Configure the script to execute a remote command (supplying credentials securely from TeamCity):
   ```powershell
   # Construct credentials from TeamCity variables
   $secPassword = ConvertTo-SecureString "%password%" -AsPlainText -Force
   $domainUser = if ("%USER_DOMAIN%") { "%USER_DOMAIN%\%user%" } else { "%user%" }
   $cred = New-Object System.Management.Automation.PSCredential($domainUser, $secPassword)

   # First, synchronize script and php-config files to a temporary folder on the remote server
   net use \\PROD-SERVER-01\C$ /user:$domainUser %password%
   xcopy /Y /I /E "deploy_php.ps1" "\\PROD-SERVER-01\C$\temp\deploy\"
   xcopy /Y /I /E "php-config\*" "\\PROD-SERVER-01\C$\temp\deploy\php-config\"
   net use \\PROD-SERVER-01\C$ /delete

   # Execute the script remotely on Server
   Invoke-Command -ComputerName "PROD-SERVER-01" -Credential $cred -ScriptBlock {
       powershell.exe -ExecutionPolicy Bypass -File "C:\temp\deploy\deploy_php.ps1" -PhpMajorVersion "8.3" -TargetPhpDir "C:\PHP\PHP8.3" -RepoConfigDir "C:\temp\deploy\php-config"
   }
   ```

---

## 9. Sharing with the Community

When publishing these utilities to other teams, package the following contents:

### 1. Directory Structure
```text
├── .teamcity/                      # Versioned settings folder
│   └── settings.kts                # Auto-importer Kotlin script (Recipients, Robocopy, PHP, S3/CloudFront)
├── connect_recipients.bat          # Mounting utility
├── disconnect_recipients.bat       # Unmounting utility
├── copy_recipients.bat             # Recipient batch deployment
├── deploy_robocopy_recipients.bat  # Robocopy folder synchronization
├── deploy_s3_cloudfront.bat        # AWS S3 & CloudFront batch launcher
├── deploy_s3_cloudfront.ps1        # AWS S3 & CloudFront deployment engine
├── deploy_php.ps1                  # PowerShell dynamic PHP updater
├── README.md                       # Comprehensive guide
├── tests/                          # Automated tests folder
│   ├── run_tests.ps1               # Tests verification runner (8 test cases)
│   └── mock-config/                # Mock configuration sandbox files
└── php-config/                     # Folder for custom php.ini and extension DLLs
```

### 2. Versioned Settings (Kotlin DSL)
By including the `.teamcity/settings.kts` script in the root directory, teams can import this pipeline automatically.

#### How to Enable Versioned Settings:
1. In TeamCity, go to your Project and select **Versioned Settings** from the sidebar.
2. Select **Synchronization enabled**.
3. Set your VCS root configuration.
4. Choose **Kotlin** format.
5. Apply settings. TeamCity will parse the `.teamcity/settings.kts` file and create the build configurations with prompt variables and testing gates pre-configured.

---

## 10. Testing

A dedicated automated test suite is located in the `tests/` folder to validate parameter passing, fallback configurations, and expected commands parsing without requiring live server updates.

### Run Automated Tests
Execute the test runner script from the root of the workspace directory:
```powershell
powershell.exe -ExecutionPolicy Bypass -File tests/run_tests.ps1
```
The runner executes 8 validation test cases in dry-run mode and outputs a summary. All test inputs are self-contained.
