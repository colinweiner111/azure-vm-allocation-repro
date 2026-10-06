#requires -Version 7.2

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Location,

    [Parameter(Mandatory)]
    [ValidateSet('1', '2', '3')]
    [string] $Zone,

    [Parameter(Mandatory)]
    [ValidateLength(1, 15)]
    [string] $VmName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $VmSize,

    [ValidateNotNullOrEmpty()]
    [string] $ImageSku = '2025-datacenter-g2',

    [string] $AdminUsername,

    [SecureString] $AdminPassword,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $VnetName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $VnetResourceGroup,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubnetName
)

$ErrorActionPreference = 'Stop'

function Assert-AdminUsername {
    param([string] $Username)

    $reservedUsernames = @(
        'admin', 'administrator', 'administrator1', 'admin1', 'admin2',
        'azure', 'david', 'guest', 'root', 'sql', 'support',
        'test', 'test1', 'test2', 'user', 'user1', 'user2', 'user3',
        'user4', 'user5', 'video'
    )
    if ([string]::IsNullOrWhiteSpace($Username)) {
        throw 'The VM administrator username cannot be empty.'
    }
    if ($reservedUsernames -contains $Username.ToLowerInvariant()) {
        throw "The VM administrator username '$Username' is reserved by Azure."
    }
    if ($Username -notmatch '^[A-Za-z][A-Za-z0-9._-]{0,19}$' -or $Username.EndsWith('.')) {
        throw 'The VM administrator username must start with a letter, contain only letters, numbers, periods, hyphens, or underscores, and be 1-20 characters.'
    }
}

function Assert-AdminPassword {
    param([string] $Password)

    if ([string]::IsNullOrEmpty($Password)) {
        throw 'The VM administrator password cannot be empty.'
    }
    if ($Password.Length -lt 8 -or $Password.Length -gt 123) {
        throw 'The VM administrator password must contain 8-123 characters.'
    }
    $classes = 0
    foreach ($pattern in @('[a-z]', '[A-Z]', '[0-9]', '[\W_]')) {
        if ($Password -cmatch $pattern) {
            $classes++
        }
    }
    if ($classes -lt 3) {
        throw 'The VM administrator password must contain at least three of lowercase, uppercase, digit, and special characters.'
    }
}

if ([string]::IsNullOrWhiteSpace($AdminUsername)) {
    $AdminUsername = Read-Host 'Enter VM administrator username'
}
Assert-AdminUsername $AdminUsername
if (-not $AdminPassword) {
    $AdminPassword = Read-Host 'Enter VM administrator password' -AsSecureString
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required.'
}

az account show --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    az login --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to sign in to Azure.'
    }
}

az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to select the requested Azure subscription.'
}

$resourceGroupExists = az group exists --name $ResourceGroupName --output tsv 2>$null
if ($LASTEXITCODE -ne 0 -or $resourceGroupExists -ne 'true') {
    throw "Resource group '$ResourceGroupName' does not exist in subscription '$SubscriptionId'."
}

$templateFile = Join-Path (Join-Path $PSScriptRoot 'infra') 'main.zonal.bicep'
$deploymentName = "e48bds-v5-zone$Zone-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$temporaryParametersFile = Join-Path ([System.IO.Path]::GetTempPath()) "vm-deploy-$([guid]::NewGuid().ToString('N')).parameters.json"
$plainTextAdminPassword = $null
$deploymentExitCode = 1

Write-Host "Deploying $VmSize as '$VmName' in logical availability zone $Zone in $Location."
Write-Host "ARM deployment name: $deploymentName"

try {
    $passwordBuffer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
    try {
        $plainTextAdminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordBuffer)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBuffer)
    }
    Assert-AdminPassword $plainTextAdminPassword

    $secureParameters = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = @{
            adminPassword = @{
                value = $plainTextAdminPassword
            }
        }
    }
    $secureParameters | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryParametersFile -Encoding utf8NoBOM

    $deploymentArguments = @(
        'deployment', 'group', 'create',
        '--resource-group', $ResourceGroupName,
        '--name', $deploymentName,
        '--template-file', $templateFile,
        '--parameters', $temporaryParametersFile,
        "location=$Location",
        "vmName=$VmName",
        "vmSize=$VmSize",
        "imageSku=$ImageSku",
        "adminUsername=$AdminUsername",
        "vnetName=$VnetName",
        "vnetResourceGroup=$VnetResourceGroup",
        "subnetName=$SubnetName"
    )
    $deploymentArguments += "zone=$Zone"

    & az @deploymentArguments
    $deploymentExitCode = $LASTEXITCODE
}
finally {
    $plainTextAdminPassword = $null
    $AdminPassword = $null
    if (Test-Path -LiteralPath $temporaryParametersFile) {
        Remove-Item -LiteralPath $temporaryParametersFile -Force
    }
}

$deployment = az deployment group show `
    --resource-group $ResourceGroupName `
    --name $deploymentName `
    --query '{correlationId:properties.correlationId,provisioningState:properties.provisioningState}' `
    --output json 2>$null | ConvertFrom-Json
$deploymentLookupExitCode = $LASTEXITCODE

if ($deploymentExitCode -ne 0) {
    if ($deploymentLookupExitCode -eq 0 -and $deployment) {
        Write-Warning "Deployment failed. Correlation ID: $($deployment.correlationId)"
        az deployment operation group list `
            --resource-group $ResourceGroupName `
            --name $deploymentName `
            --query "[?properties.provisioningState=='Failed'].{resource:properties.targetResource.resourceName, resourceType:properties.targetResource.resourceType, error:properties.statusMessage}" `
            --output jsonc
    }
    throw "Azure deployment '$deploymentName' failed."
}

Write-Host "Deployment '$deploymentName' succeeded."
Write-Host "Correlation ID: $($deployment.correlationId)"
