[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$Version,
    [string]$ApiKey = $env:NUGET_API_KEY,
    [string]$Source = 'https://api.nuget.org/v3/index.json',
    [switch]$SkipDuplicate,
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
        '--api-key' {
            $i++
            if ($i -ge $RemainingArguments.Count) { throw 'Missing value for --api-key.' }
            $ApiKey = $RemainingArguments[$i]
        }
        '--source' {
            $i++
            if ($i -ge $RemainingArguments.Count) { throw 'Missing value for --source.' }
            $Source = $RemainingArguments[$i]
        }
        '--skip-duplicate' { $SkipDuplicate = $true }
        default { throw "Unexpected argument '$($RemainingArguments[$i])'." }
    }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    throw 'Version is required. Use -Version 1.0.1-alpha or --version 1.0.1-alpha.'
}

Import-Module (Join-Path $PSScriptRoot 'koreforge-build.psm1') -Force -DisableNameChecking
Invoke-KoreForgeReleaseNuGetFromLocal -Version $Version -ApiKey $ApiKey -Source $Source -SkipDuplicate:$SkipDuplicate
