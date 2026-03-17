<#
.SYNOPSIS
    Cleans build artifacts.
#>

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Cleaning: $(Split-Path $repoRoot -Leaf)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$foldersToClean = @('bin', 'obj', 'artifacts')

foreach ($folder in $foldersToClean) {
    $paths = Get-ChildItem -Path $repoRoot -Directory -Recurse -Filter $folder -ErrorAction SilentlyContinue
    foreach ($path in $paths) {
        Write-Host "[Clean] Removing: $($path.FullName)" -ForegroundColor Yellow
        Remove-Item -Path $path.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "[Clean] Clean completed." -ForegroundColor Green
