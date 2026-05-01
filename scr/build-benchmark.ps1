[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

Import-Module (Join-Path $PSScriptRoot 'koreforge-build.psm1') -Force -DisableNameChecking
Invoke-KfBenchmark -Configuration $Configuration

