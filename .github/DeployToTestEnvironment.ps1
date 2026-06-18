Param(
    [Hashtable] $parameters
)

$publish = ($parameters.Type -eq "publish")
$includeTestAppsInSandboxEnvironment = $parameters.IncludeTestAppsInSandboxEnvironment

Write-Host "Import Deploy.psm1 from AL-Go"
$caller = (Get-PSCallStack)[1]
$scriptName = $caller.ScriptName   # e.g. C:\...\Actions\Deploy\Deploy.ps1
if ($scriptName -notlike "*Deploy.ps1") {
    throw "This script is meant to be called from AL-Go's Deploy.ps1. Calling it directly is not supported."
}
$psmModule = $scriptName -replace "Deploy\.ps1$", "Deploy.psm1"
import-Module $psmModule -Force -DisableNameChecking

# Calculate unknown dependencies for all apps and known dependencies
$unknownDependencies = @()
Sort-AppFilesByDependencies -appFiles @($parameters.apps + $parameters.dependencies) -unknownDependencies ([ref]$unknownDependencies) -WarningAction SilentlyContinue | Out-Null

$environmentName = $parameters.EnvironmentName

$tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ([GUID]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tempPath | Out-Null
Copy-AppFilesToFolder -appFiles $parameters.apps -folder $tempPath | Out-Null
$appsList = @(Get-ChildItem -Path $tempPath -Filter *.app)
if (-not $appsList -or $appsList.Count -eq 0) {
    Write-Host "::error::No apps to publish found."
    exit 1
}

try {
    $authContext = $parameters.AuthContext | ConvertFrom-Json | ConvertTo-HashTable
    $authContext."Scopes" = "https://projectmadeira.com/.default"
    $bcAuthContext = New-BcAuthContext @authContext
    if ($null -eq $bcAuthContext) {
        throw "Authentication failed"
    }
} catch {
    throw "Authentication failed. $([environment]::Newline) $($_.exception.message)"
}
$environmentUrl = "$($bcContainerHelperConfig.baseUrl.TrimEnd('/'))/$($bcAuthContext.tenantId)/$($environmentName)"
Add-Content -Encoding UTF8 -Path $env:GITHUB_OUTPUT -Value "environmentUrl=$environmentUrl"
Write-Host "EnvironmentUrl: $environmentUrl"
$response = Invoke-RestMethod -UseBasicParsing -Method Get -Uri "$environmentUrl/deployment/url"
if ($response.Status -eq "DoesNotExist") {
    throw "Environment with name $($environmentName) does not exist in the current authorization context."
}
if ($response.Status -ne "Ready") {
    throw "Environment with name $($environmentName) is not ready (Status is $($response.Status))."
}
$sandboxEnvironment = ($response.environmentType -eq 1)
if (-not $sandboxEnvironment) {
    throw "Environment $($environmentName) is not a sandbox environment. Deployment can only be done to sandbox environments."
}
$scope = $parameters.Scope
if (-not $scope) {
    $scope = "DEV"
}
$artifactVersion = $null
Write-Host "Determine artifacts:"
Get-BcEnvironmentInstalledExtensions -environment $environmentName -bcAuthContext $bcAuthContext | ForEach-Object {
    $version = [System.Version]::new($_.VersionMajor, $_.VersionMinor, $_.VersionBuild, $_.VersionRevision)
    if ($_.publisher -eq "Microsoft" -and $_.displayName -eq "Base Application") {
        Write-Host "Base Application version in environment is $version"
        $artifactVersion = $version
    }
}
if (-not $artifactVersion) {
    throw "Could not determine Base Application version in environment. Make sure the environment is properly set up and has the Base Application installed."
}

if ($dependencies) {
    InstallOrUpgradeApps -bcAuthContext $bcAuthContext -environment $environmentName -Apps $parameters.dependencies -installMode $parameters.DependencyInstallMode
}
if ($unknownDependencies) {
    InstallUnknownDependencies -bcAuthContext $bcAuthContext -environment $environmentName -Apps $unknownDependencies -installMode $parameters.DependencyInstallMode
}
if ($scope -eq 'Dev') {
    $publishParameters = @{
        "bcAuthContext" = $bcAuthContext
        "environment" = $environmentName
        "appFile" = $appsList
    }
    if ($parameters.SyncMode) {
        if (@('Add','ForceSync', 'Clean', 'Development') -notcontains $parameters.SyncMode) {
            throw "Invalid SyncMode $($parameters.SyncMode) when deploying using the development endpoint. Valid values are Add, ForceSync, Development and Clean."
        }
        Write-Host "Using $($parameters.SyncMode)"
        $publishParameters += @{ "SyncMode" = $parameters.SyncMode }
    }
    Write-Host "Publishing apps using development endpoint"
    Publish-BcContainerApp @publishParameters -useDevEndpoint -checkAlreadyInstalled -excludeRuntimePackages -replacePackageId
}
else {
    # Use automation API for production environments (Publish-PerTenantExtensionApps)
    $publishParameters = @{
        "bcAuthContext" = $bcAuthContext
        "environment" = $environmentName
        "appFiles" = $appsList
    }
    if ($parameters.SyncMode) {
        if (@('Add','ForceSync') -notcontains $parameters.SyncMode) {
            throw "Invalid SyncMode $($parameters.SyncMode) when deploying using the automation API. Valid values are Add and ForceSync."
        }
        Write-Host "Using $($parameters.SyncMode)"
        $syncMode = $parameters.SyncMode
        if ($syncMode -eq 'ForceSync') { $syncMode = 'Force' }
        $publishParameters += @{ "SchemaSyncMode" = $syncMode }
    }
    CheckInstalledApps -bcAuthContext $bcAuthContext -environment $environmentName -appFiles $appsList
    Write-Host "Publishing apps using automation API"
    Publish-PerTenantExtensionApps @publishParameters
}

if (-not $includeTestAppsInSandboxEnvironment) {
    Write-Host "Not including test apps in sandbox environment, skipping test runs"
    exit
}

if ($publish) {
    Write-Host "Publishing done, not running tests during publish"
    # exit
}

$testResultsFile = Join-Path $ENV:GITHUB_WORKSPACE "TestResults.xml"

$artifactUrl = Get-BcArtifactUrl -type Sandbox -version $artifactVersion -country 'w1' -select Closest
$compilerFolder = New-BcCompilerFolder -artifactUrl $artifactUrl
Write-Host "Running tests"
$appsList | ForEach-Object { 
    $appJson = Get-AppJsonFromAppFile -appFile $_.FullName
    $appId = $appJson.id
    $isTestApp = $false
    $appJson.Dependencies | ForEach-Object {
        if ($testRunnerApps -contains $_.id) {
            $isTestApp = $true
        }
    }
    if ($isTestApp) {
        Write-Host "Running tests for app $($_.Name) with id $appId"
        $Parameters = @{
            "extensionId" = $appId
            "appName" = $appJson.Name
            "GitHubActions" = "error"
            "detailed" = $true
            "returnTrueIfAllPassed" = $true
            "JUnitResultFileName" = $testResultsFile
            "AppendToJUnitResultFile" = $true
            "bcAuthContext" = $bcAuthContext
            "environment" = $environmentName
            "CompilerFolder" = $compilerFolder
            "ConnectFromHost" = $true
        }
        Run-TestsInBcContainer @Parameters
    }
}
