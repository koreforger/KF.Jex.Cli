Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-KfRepoRoot {
    (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Get-KfBuildTarget {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $solutionX = Get-ChildItem -Path $RepoRoot -Filter '*.slnx' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
    if ($solutionX) { return $solutionX.FullName }

    $project = Get-ChildItem -Path $RepoRoot -Filter '*.csproj' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
    if ($project) { return $project.FullName }

    throw "No .slnx or root .csproj build target found in $RepoRoot."
}

function Ensure-KfLocalNuGetSources {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $nugetConfig = Join-Path $RepoRoot 'NuGet.config'
    if (-not (Test-Path $nugetConfig)) { return }

    try { [xml]$config = Get-Content -Path $nugetConfig -Raw }
    catch { return }

    $sources = @($config.configuration.packageSources.add)
    foreach ($source in $sources) {
        $value = [string]$source.value
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if ($value -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') { continue }

        $path = if ([System.IO.Path]::IsPathRooted($value)) { $value } else { Join-Path $RepoRoot $value }
        New-Item -Path $path -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
}

function Invoke-KfDotNet {
    param([Parameter(Mandatory)][string[]]$Arguments)

    Write-Host "dotnet $($Arguments -join ' ')" -ForegroundColor DarkCyan
    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet command failed with exit code ${LASTEXITCODE}: dotnet $($Arguments -join ' ')"
    }
}

function Invoke-KfNativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    Write-Host "$FilePath $($Arguments -join ' ')" -ForegroundColor DarkCyan
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

function Get-KfRelativePath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path
    )

    return [System.IO.Path]::GetRelativePath($RepoRoot, $Path).Replace('/', '\')
}

function Get-KfProjectFiles {
    param([Parameter(Mandatory)][string]$RepoRoot)

    Get-ChildItem -Path $RepoRoot -Filter '*.csproj' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } |
        Sort-Object FullName
}

function Test-KfProjectContains {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Project,
        [Parameter(Mandatory)][string]$Pattern
    )

    return [bool](Select-String -Path $Project.FullName -Pattern $Pattern -Quiet -SimpleMatch)
}

function Get-KfTestProjects {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Integration
    )

    Get-KfProjectFiles -RepoRoot $RepoRoot |
        Where-Object { Test-KfProjectContains -Project $_ -Pattern 'Microsoft.NET.Test.Sdk' } |
        Where-Object {
            $isIntegration = $_.BaseName -match 'Integration'
            if ($Integration) { $isIntegration } else { -not $isIntegration }
        }
}

function Get-KfBenchmarkProjects {
    param([Parameter(Mandatory)][string]$RepoRoot)

    Get-KfProjectFiles -RepoRoot $RepoRoot |
        Where-Object { $_.BaseName -match 'Benchmark' -or (Test-KfProjectContains -Project $_ -Pattern 'BenchmarkDotNet') }
}

function Invoke-KfClean {
    param([string]$Configuration = 'Debug')

    $repoRoot = Get-KfRepoRoot
    $target = Get-KfBuildTarget -RepoRoot $repoRoot

    Push-Location $repoRoot
    try {
        Invoke-KfDotNet @('clean', $target, '-c', $Configuration, '--verbosity', 'minimal')
        Remove-Item 'out', 'artifacts' -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host 'Clean complete.' -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Invoke-KfRebuild {
    param([string]$Configuration = 'Debug')

    $repoRoot = Get-KfRepoRoot
    $target = Get-KfBuildTarget -RepoRoot $repoRoot

    Push-Location $repoRoot
    try {
        Ensure-KfLocalNuGetSources -RepoRoot $repoRoot
        Invoke-KfDotNet @('build', $target, '--force', '-c', $Configuration)
        Write-Host 'Rebuild complete.' -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Invoke-KfTest {
    param([string]$Configuration = 'Debug')

    $repoRoot = Get-KfRepoRoot
    $target = Get-KfBuildTarget -RepoRoot $repoRoot
    $testProjects = @(Get-KfTestProjects -RepoRoot $repoRoot)

    Push-Location $repoRoot
    try {
        if ($testProjects.Count -eq 0) {
            Write-Host 'No unit test projects found.' -ForegroundColor Yellow
            return
        }

        Ensure-KfLocalNuGetSources -RepoRoot $repoRoot
        Invoke-KfDotNet @('build', $target, '--force', '-c', $Configuration)

        New-Item -Path 'out/TestResults' -ItemType Directory -Force | Out-Null
        Invoke-KfDotNet @(
            'test', $target,
            '-c', $Configuration,
            '--no-build',
            '--filter', 'FullyQualifiedName!~Integration',
            '--logger', 'html;LogFileName=TestResults.html',
            '--results-directory', 'out/TestResults'
        )
        Write-Host 'Test results: out/TestResults/TestResults.html' -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Invoke-KfCoverage {
    param(
        [string]$Configuration = 'Debug',
        [switch]$Open
    )

    $repoRoot = Get-KfRepoRoot
    $target = Get-KfBuildTarget -RepoRoot $repoRoot
    $testProjects = @(Get-KfTestProjects -RepoRoot $repoRoot)

    Push-Location $repoRoot
    try {
        if ($testProjects.Count -eq 0) {
            Write-Host 'No unit test projects found.' -ForegroundColor Yellow
            return
        }

        Ensure-KfLocalNuGetSources -RepoRoot $repoRoot
        Invoke-KfDotNet @('build', $target, '--force', '-c', $Configuration)

        New-Item -Path 'out/TestResults' -ItemType Directory -Force | Out-Null
        $testArgs = @(
            'test', $target,
            '-c', $Configuration,
            '--no-build',
            '--filter', 'FullyQualifiedName!~Integration',
            '--logger', 'html;LogFileName=TestResults.html',
            '--results-directory', 'out/TestResults',
            '--collect', 'XPlat Code Coverage'
        )

        if (Test-Path 'coverlet.runsettings') {
            $testArgs += @('--settings', 'coverlet.runsettings')
        }

        Invoke-KfDotNet $testArgs

        $coverageFiles = @(Get-ChildItem -Path 'out/TestResults' -Recurse -File -Filter 'coverage.cobertura.xml' -ErrorAction SilentlyContinue)
        if ($coverageFiles.Count -eq 0) {
            Write-Host 'No Cobertura coverage files were produced.' -ForegroundColor Yellow
            return
        }

        $reportArgs = @(
            '-reports:out/TestResults/**/coverage.cobertura.xml',
            '-targetdir:out/TestResults/coverage',
            '-reporttypes:Html;Cobertura'
        )

        if (Test-Path '.config/dotnet-tools.json') {
            Invoke-KfDotNet @('tool', 'restore')
            Invoke-KfDotNet (@('tool', 'run', 'reportgenerator') + $reportArgs)
        }
        elseif (Get-Command reportgenerator -ErrorAction SilentlyContinue) {
            Invoke-KfNativeCommand -FilePath 'reportgenerator' -Arguments $reportArgs
        }
        else {
            $toolPath = Join-Path $repoRoot 'out/tools'
            New-Item -Path $toolPath -ItemType Directory -Force | Out-Null
            Invoke-KfDotNet @('tool', 'install', 'dotnet-reportgenerator-globaltool', '--tool-path', $toolPath)
            $reportGenerator = Join-Path $toolPath 'reportgenerator'
            Invoke-KfNativeCommand -FilePath $reportGenerator -Arguments $reportArgs
        }

        if ($Open) {
            Invoke-Item (Resolve-Path 'out/TestResults/coverage/index.html')
        }

        Write-Host 'Coverage report: out/TestResults/coverage/index.html' -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Invoke-KfIntegration {
    param([string]$Configuration = 'Debug')

    $repoRoot = Get-KfRepoRoot
    $target = Get-KfBuildTarget -RepoRoot $repoRoot
    $integrationProjects = @(Get-KfTestProjects -RepoRoot $repoRoot -Integration)

    Push-Location $repoRoot
    try {
        if ($integrationProjects.Count -eq 0) {
            Write-Host 'No integration test projects found.' -ForegroundColor Yellow
            return
        }

        Ensure-KfLocalNuGetSources -RepoRoot $repoRoot
        Invoke-KfDotNet @('build', $target, '--force', '-c', $Configuration)

        New-Item -Path 'out/TestResults' -ItemType Directory -Force | Out-Null
        foreach ($project in $integrationProjects) {
            $relativeProject = Get-KfRelativePath -RepoRoot $repoRoot -Path $project.FullName
            $logName = "$($project.BaseName).trx"
            Invoke-KfDotNet @(
                'test', $relativeProject,
                '-c', $Configuration,
                '--no-build',
                '--logger', "trx;LogFileName=$logName",
                '--results-directory', 'out/TestResults'
            )
        }

        Write-Host 'Test results: out/TestResults' -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Invoke-KfBenchmark {
    param([string]$Configuration = 'Release')

    $repoRoot = Get-KfRepoRoot
    $benchmarkProjects = @(Get-KfBenchmarkProjects -RepoRoot $repoRoot)

    Push-Location $repoRoot
    try {
        if ($benchmarkProjects.Count -eq 0) {
            Write-Host 'No benchmark projects found.' -ForegroundColor Yellow
            return
        }

        foreach ($project in $benchmarkProjects) {
            $relativeProject = Get-KfRelativePath -RepoRoot $repoRoot -Path $project.FullName
            Invoke-KfDotNet @('run', '--project', $relativeProject, '-c', $Configuration, '--')
        }

        Write-Host 'Benchmark complete.' -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Invoke-KfPack {
    param(
        [string]$Configuration = 'Release',
        [string]$Version,
        [switch]$NoBuild
    )

    $repoRoot = Get-KfRepoRoot
    $target = Get-KfBuildTarget -RepoRoot $repoRoot

    Push-Location $repoRoot
    try {
        Ensure-KfLocalNuGetSources -RepoRoot $repoRoot
        New-Item -Path 'artifacts' -ItemType Directory -Force | Out-Null
        $args = @('pack', $target, '-c', $Configuration, '-o', 'artifacts')
        if ($NoBuild) { $args += '--no-build' }
        if ($Version) { $args += @('/p:PackageVersion=' + $Version, '/p:Version=' + $Version) }
        Invoke-KfDotNet $args
        Write-Host 'Packages written to artifacts/.' -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Get-KfNuGetReleaseTagPrefix {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $workflowDir = Join-Path $RepoRoot '.github/workflows'
    if (Test-Path $workflowDir) {
        $workflowFiles = @(
            Get-ChildItem -Path $workflowDir -File -Filter '*.yml' -ErrorAction SilentlyContinue
            Get-ChildItem -Path $workflowDir -File -Filter '*.yaml' -ErrorAction SilentlyContinue
        )
        foreach ($workflow in $workflowFiles | Sort-Object Name) {
            $match = Select-String -Path $workflow.FullName -Pattern "'([^']+/v)\*'" | Select-Object -First 1
            if ($match -and $match.Matches.Count -gt 0) {
                return $match.Matches[0].Groups[1].Value
            }
        }
    }

    return ((Split-Path $RepoRoot -Leaf) + '/v')
}

function Invoke-KfReleaseNuGetFromGitHub {
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$Note,
        [switch]$Force,
        [switch]$AllowDirty
    )

    $repoRoot = Get-KfRepoRoot
    Push-Location $repoRoot
    try {
        if (-not $AllowDirty -and (git status --porcelain)) {
            throw 'The repository has uncommitted changes. Commit or stash them before creating a release tag, or pass -AllowDirty explicitly.'
        }

        $tag = (Get-KfNuGetReleaseTagPrefix -RepoRoot $repoRoot) + $Version
        $tagMessage = if ($Note) { $Note } else { "Release $Version" }

        if ($Force) {
            git tag --force -a $tag -m $tagMessage
            if ($LASTEXITCODE -ne 0) { throw "Failed to create tag $tag." }
            git push origin --force-with-lease "refs/tags/$tag"
            if ($LASTEXITCODE -ne 0) { throw "Failed to push tag $tag." }
        }
        else {
            git tag -a $tag -m $tagMessage
            if ($LASTEXITCODE -ne 0) { throw "Failed to create tag $tag." }
            git push origin $tag
            if ($LASTEXITCODE -ne 0) { throw "Failed to push tag $tag." }
        }

        Write-Host "Tagged and pushed $tag" -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Invoke-KfReleaseNuGetFromLocal {
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$ApiKey = $env:NUGET_API_KEY,
        [string]$Source = 'https://api.nuget.org/v3/index.json',
        [switch]$SkipDuplicate
    )

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw 'NuGet API key is required. Pass -ApiKey or set NUGET_API_KEY.'
    }

    $repoRoot = Get-KfRepoRoot
    $target = Get-KfBuildTarget -RepoRoot $repoRoot
    $testProjects = @(Get-KfTestProjects -RepoRoot $repoRoot)

    Push-Location $repoRoot
    try {
        Remove-Item 'artifacts' -Recurse -Force -ErrorAction SilentlyContinue
        Ensure-KfLocalNuGetSources -RepoRoot $repoRoot
        Invoke-KfDotNet @('build', $target, '--force', '-c', 'Release')

        if ($testProjects.Count -gt 0) {
            New-Item -Path 'out/TestResults' -ItemType Directory -Force | Out-Null
            Invoke-KfDotNet @(
                'test', $target,
                '-c', 'Release',
                '--no-build',
                '--filter', 'FullyQualifiedName!~Integration',
                '--logger', 'html;LogFileName=TestResults.html',
                '--results-directory', 'out/TestResults'
            )
        }

        Invoke-KfPack -Configuration 'Release' -Version $Version -NoBuild

        $packages = @(Get-ChildItem -Path 'artifacts' -Filter '*.nupkg' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.symbols.nupkg' })
        if ($packages.Count -eq 0) {
            throw 'No NuGet packages were produced under artifacts/.'
        }

        foreach ($package in $packages) {
            $pushArgs = @('nuget', 'push', $package.FullName, '--api-key', $ApiKey, '--source', $Source)
            if ($SkipDuplicate) { $pushArgs += '--skip-duplicate' }
            Invoke-KfDotNet $pushArgs
        }

        Write-Host "Released $($packages.Count) package(s) from local build." -ForegroundColor Green
    }
    finally { Pop-Location }
}





