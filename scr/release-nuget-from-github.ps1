[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$Version,
    [string]$Note,
    [switch]$Force,
    [switch]$AllowDirty,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments
)

for ($i = 0; $i -lt $RemainingArguments.Count; $i++) {
    switch ($RemainingArguments[$i]) {
        '--version' {
            $i++
            if ($i -ge $RemainingArguments.Count) { throw 'Missing value for --version.' }
            $Version = $RemainingArguments[$i]
        }
        '--note' {
            $i++
            if ($i -ge $RemainingArguments.Count) { throw 'Missing value for --note.' }
            $Note = $RemainingArguments[$i]
        }
        '--force' { $Force = $true }
        '--allow-dirty' { $AllowDirty = $true }
        default { throw "Unexpected argument '$($RemainingArguments[$i])'." }
    }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    throw 'Version is required. Use -Version 1.0.1-alpha or --version 1.0.1-alpha.'
}

Import-Module (Join-Path $PSScriptRoot 'koreforge-build.psm1') -Force -DisableNameChecking
Invoke-KoreForgeReleaseNuGetFromGitHub -Version $Version -Note $Note -Force:$Force -AllowDirty:$AllowDirty
