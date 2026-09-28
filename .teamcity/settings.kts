import jetbrains.buildServer.configs.kotlin.*
import jetbrains.buildServer.configs.kotlin.buildSteps.script
import jetbrains.buildServer.configs.kotlin.buildSteps.powerShell

/*
==============================================================================
TeamCity Kotlin DSL Configuration for Deployment Pipeline
==============================================================================
This settings file configures versioned settings for TeamCity.
When checked into the repository root as `.teamcity/settings.kts`, TeamCity
will automatically read this file and create the project builds.
==============================================================================
*/

version = "2024.03"

project {
    description = "Pipeline configurations for file deployments and PHP updates"

    buildType(DeployRecipientsBuild)
    buildType(DeployPhpBuild)
    buildType(DeployS3CloudFrontBuild)
}

// -------------------------------------------------------------------
// Build Configuration 1: Deploy Recipients and Sync Files
// -------------------------------------------------------------------
object DeployRecipientsBuild : BuildType({
    id("DeployRecipientsAndSync")
    name = "1. Deploy Recipients & Mirror Sync"
    description = "Validates with tests, deletes old copies, copies files for recipients, and syncs folders using Robocopy"

    params {
        text("env.DEPLOY_SERVER", "", display = ParameterDisplay.PROMPT, label = "Target Server UNC Path", description = "Target server path, e.g. \\\\PROD-SERVER-01\\share")
        text("env.user", "", display = ParameterDisplay.PROMPT, label = "Username", description = "Active Directory or local user name")
        text("env.USER_DOMAIN", "", display = ParameterDisplay.NORMAL, label = "Active Directory Domain", description = "Optional domain name (e.g. CORP). Leave empty if not using AD domain.")
        password("env.password", "", display = ParameterDisplay.PROMPT, label = "Password", description = "User password")
        text("env.RECIPIENT_LIST", "", display = ParameterDisplay.PROMPT, label = "Recipients List (Space Separated)", description = "List of directories to deploy, e.g. partner1 partner2")
    }

    vcs {
        root(RelativeId("VCS_ROOT_ID")) // Set to your VCS root ID in TeamCity
    }

    steps {
        script {
            name = "Run Local Automated Tests Suite"
            scriptContent = "powershell.exe -ExecutionPolicy Bypass -File tests/run_tests.ps1"
        }
        script {
            name = "Deploy Recipient Files"
            scriptContent = "cmd.exe /c copy_recipients.bat"
        }
        script {
            name = "Robocopy Mirror Synchronization"
            scriptContent = "cmd.exe /c deploy_robocopy_recipients.bat"
        }
    }
})

// -------------------------------------------------------------------
// Build Configuration 2: Auto-Update PHP Core and Configurations
// -------------------------------------------------------------------
object DeployPhpBuild : BuildType({
    id("DeployPhpUpdates")
    name = "2. Deploy PHP Core & Config Updates"
    description = "Downloads the latest PHP binaries, stops IIS, deploys core files, php.ini, and custom extensions"

    params {
        text("PHP_MAJOR_VERSION", "8.3", display = ParameterDisplay.PROMPT, label = "PHP Major Version", description = "e.g. 8.3, 8.4, 8.5")
        text("TARGET_PHP_DIR", "C:\\PHP\\PHP%PHP_MAJOR_VERSION%", label = "Target PHP Directory on Server", description = "Path where PHP binaries should be deployed")
        password("password", "", display = ParameterDisplay.PROMPT, label = "Server Password", description = "Administrator password to start/stop IIS services (W3SVC)")
        text("user", "", display = ParameterDisplay.PROMPT, label = "Server Username", description = "Administrator user name")
    }

    vcs {
        root(RelativeId("VCS_ROOT_ID")) // Set to your VCS root ID in TeamCity
    }

    steps {
        powerShell {
            name = "Run PHP Auto-Updater"
            scriptMode = file {
                path = "deploy_php.ps1"
            }
            noProfile = true
            param("jetbrains.buildServer.powershell.args", "-PhpMajorVersion %PHP_MAJOR_VERSION% -TargetPhpDir %TARGET_PHP_DIR%")
        }
    }
})

// -------------------------------------------------------------------
// Build Configuration 3: Deploy Projects & Recipients to S3 & CloudFront
// -------------------------------------------------------------------
object DeployS3CloudFrontBuild : BuildType({
    id("DeployS3CloudFront")
    name = "3. Deploy to AWS S3 & CloudFront"
    description = "Syncs recipient folders or source project directory to Amazon S3 and invalidates CloudFront cache"

    params {
        text("env.AWS_S3_BUCKET", "", display = ParameterDisplay.PROMPT, label = "AWS S3 Bucket Name", description = "Target S3 bucket name (e.g. my-app-production-bucket)")
        text("env.CLOUDFRONT_DISTRIBUTION_ID", "", display = ParameterDisplay.PROMPT, label = "CloudFront Distribution ID", description = "Optional CloudFront distribution ID for cache invalidation (e.g. E123456EXAMPLE)")
        text("env.AWS_REGION", "us-east-1", display = ParameterDisplay.PROMPT, label = "AWS Region", description = "AWS region (e.g. us-east-1, us-west-2)")
        text("env.S3_PREFIX", "", display = ParameterDisplay.NORMAL, label = "S3 Prefix / Folder", description = "Optional subpath in bucket (e.g. apps/my-project)")
        text("env.RECIPIENT_LIST", "", display = ParameterDisplay.NORMAL, label = "Recipients List (Optional)", description = "Space-separated recipient folders to deploy (leave empty to deploy entire source folder)")
        text("env.SOURCE_DIR", ".", display = ParameterDisplay.NORMAL, label = "Source Directory", description = "Local directory to deploy if no recipient list is provided (e.g. . or dist)")
    }

    vcs {
        root(RelativeId("VCS_ROOT_ID")) // Set to your VCS root ID in TeamCity
    }

    steps {
        script {
            name = "Run Local Automated Tests Suite"
            scriptContent = "powershell.exe -ExecutionPolicy Bypass -File tests/run_tests.ps1"
        }
        powerShell {
            name = "Deploy to AWS S3 & Invalidate CloudFront"
            scriptMode = file {
                path = "deploy_s3_cloudfront.ps1"
            }
            noProfile = true
            param("jetbrains.buildServer.powershell.args", "-Bucket %env.AWS_S3_BUCKET% -DistributionId %env.CLOUDFRONT_DISTRIBUTION_ID% -Region %env.AWS_REGION% -S3Prefix \"%env.S3_PREFIX%\" -SourcePath \"%env.SOURCE_DIR%\"")
        }
    }
})
