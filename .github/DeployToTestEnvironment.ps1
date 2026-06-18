Param(
    [Hashtable] $parameters
)

$caller = (Get-PSCallStack)[1]
$scriptName = $caller.ScriptName   # e.g. C:\...\Actions\Deploy\Deploy.ps1
if ($scriptName -notlike "*Deploy.ps1") {
    throw "This script is meant to be called from Deploy.ps1. Calling it directly is not supported."
}
$psmModule = $scriptName -replace "Deploy\.ps1$", "Deploy.psm1"
import-Module $psmModule -Force -DisableNameChecking

$parameters | ConvertTo-Json -Depth 99 | Out-Host
Get-ChildItem -Path "ENV:" | ForEach-Object { Write-Host "$($_.Name)=$($_.Value)" }

Write-Host "Deployment Type (CD or Release): $($parameters.type)"
Write-Host "Apps to deploy: $($parameters.apps)"
Write-Host "Environment Type: $($parameters.EnvironmentType)"
Write-Host "Environment Name: $($parameters.EnvironmentName)"

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
    $bcAuthContext = New-BcAuthContext @authContextParams
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
$publish = ($parameters.Type -eq "publish")
$scope = $parameters."Scope"
if (-not $scope) {
    $scope = "DEV"
}
 Get-BcEnvironmentInstalledExtensions -environment $environmentName -bcAuthContext $bcAuthContext | ForEach-Object {
    Write-Host "Installed app: $($_.Name) - version: $($_.Version) - publisher: $($_.Publisher)"
}

Write-Host "Deploying Apps:"
$appsList | ForEach-Object { 
    Write-Host "- $($_.FullName)"
}
