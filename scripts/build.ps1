<#
.SYNOPSIS
    Builds the JEX CLI.
#>

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$solutionFile = Get-ChildItem -Path $repoRoot -Filter '*.slnx' -File | Select-Object -First 1

if (-not $solutionFile) { throw "No .slnx solution file found in $repoRoot" }

$solutionPath = $solutionFile.FullName
$solutionName = $solutionFile.BaseName

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Building: $solutionName" -ForegroundColor Cyan
Write-Host "  Configuration: $Configuration" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Push-Location $repoRoot
try {
    Write-Host "[Build] Restoring packages..." -ForegroundColor Yellow
    dotnet restore $solutionPath
    
    Write-Host "[Build] Building solution..." -ForegroundColor Yellow
    dotnet build $solutionPath -c $Configuration --no-restore
    
    Write-Host "[Build] Build completed successfully." -ForegroundColor Green
}
finally { Pop-Location }
