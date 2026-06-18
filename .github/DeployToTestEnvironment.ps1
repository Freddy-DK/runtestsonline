Param(
    [Hashtable] $parameters
)

$parameters | ForEach-Object { Write-Host "$($_.Key)=$($_.Value)" }

Get-ChildItem -Path "ENV:" | ForEach-Object { Write-Host "$($_.Name)=$($_.Value)" }

Write-Host "Deployment Type (CD or Release): $($parameters.type)"
Write-Host "Apps to deploy: $($parameters.apps)"
Write-Host "Environment Type: $($parameters.EnvironmentType)"
Write-Host "Environment Name: $($parameters.EnvironmentName)"

$tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ([GUID]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tempPath | Out-Null
Copy-AppFilesToFolder -appFiles $parameters.apps -folder $tempPath | Out-Null
$appsList = @(Get-ChildItem -Path $tempPath -Filter *.app)
if (-not $appsList -or $appsList.Count -eq 0) {
    Write-Host "::error::No apps to publish found."
    exit 1
}
Write-Host "Apps:"
$appsList | ForEach-Object { Write-Host "- $($_.Name)" }