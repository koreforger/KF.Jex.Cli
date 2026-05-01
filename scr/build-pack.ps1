[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$Version
)

Import-Module (Join-Path $PSScriptRoot 'koreforge-build.psm1') -Force -DisableNameChecking
Invoke-KfPack -Configuration $Configuration -Version $Version

