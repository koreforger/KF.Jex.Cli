[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug'
)

Import-Module (Join-Path $PSScriptRoot 'koreforge-build.psm1') -Force -DisableNameChecking
Invoke-KfClean -Configuration $Configuration

