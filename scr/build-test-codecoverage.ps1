[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug',
    [switch]$Open
)

Import-Module (Join-Path $PSScriptRoot 'koreforge-build.psm1') -Force -DisableNameChecking
Invoke-KfCoverage -Configuration $Configuration -Open:$Open

