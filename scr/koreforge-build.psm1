Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-KfRepoRoot {
    (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Get-KfWorkspaceRoot {
    param([Parameter(Mandatory)][string]$RepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($env:KFO_WORKSPACE_ROOT) -and (Test-Path $env:KFO_WORKSPACE_ROOT)) {
        return (Resolve-Path $env:KFO_WORKSPACE_ROOT).Path
    }

    $current = Get-Item -Path $RepoRoot
    while ($current) {
        if (Test-Path (Join-Path $current.FullName 'builder.config.json')) {
            return $current.FullName
        }
        $current = $current.Parent
    }

    return $RepoRoot
}

function Get-KfArtifactRoot {
    param([Parameter(Mandatory)][string]$RepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($env:KFO_ARTIFACTS_ROOT)) {
        return $env:KFO_ARTIFACTS_ROOT
    }

    return Join-Path (Get-KfWorkspaceRoot -RepoRoot $RepoRoot) 'artifacts'
}

function Get-KfRepoArtifactPath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ChildPath
    )

    $repoName = Split-Path $RepoRoot -Leaf
    return Join-Path (Get-KfArtifactRoot -RepoRoot $RepoRoot) (Join-Path 'repos' (Join-Path $repoName $ChildPath))
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

    $workspaceRoot = Get-KfWorkspaceRoot -RepoRoot $RepoRoot
    $nugetConfigs = @(
        (Join-Path $RepoRoot 'NuGet.config'),
        (Join-Path $workspaceRoot 'NuGet.config')
    ) | Sort-Object -Unique

    foreach ($nugetConfig in $nugetConfigs) {
        if (-not (Test-Path $nugetConfig)) { continue }

        try { [xml]$config = Get-Content -Path $nugetConfig -Raw }
        catch { continue }

        $configRoot = Split-Path $nugetConfig -Parent
        $sources = @($config.configuration.packageSources.add)
        foreach ($source in $sources) {
            $value = [string]$source.value
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            if ($value -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') { continue }

            $path = if ([System.IO.Path]::IsPathRooted($value)) { $value } else { Join-Path $configRoot $value }
            New-Item -Path $path -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

function Invoke-KfDotNet {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $effectiveArguments = @($Arguments)
    if ($effectiveArguments.Count -gt 0 -and $effectiveArguments[0] -in @('build', 'test', 'pack', 'clean')) {
        $repoRoot = (Get-Location).Path
        $buildRoot = Get-KfRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'build'
        $effectiveArguments += @('--artifacts-path', $buildRoot)
    }

    Write-Host "dotnet $($effectiveArguments -join ' ')" -ForegroundColor DarkCyan
    & dotnet @effectiveArguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet command failed with exit code ${LASTEXITCODE}: dotnet $($effectiveArguments -join ' ')"
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

function Get-KfPackableProjects {
    param([Parameter(Mandatory)][string]$RepoRoot)

    Get-KfProjectFiles -RepoRoot $RepoRoot |
        Where-Object { -not (Test-KfProjectContains -Project $_ -Pattern '<IsPackable>false</IsPackable>') } |
        Where-Object { -not (Test-KfProjectContains -Project $_ -Pattern 'Microsoft.NET.Test.Sdk') } |
        Where-Object { $_.FullName -notmatch '\\(templates?|samples?|benchmarks?)\\' }
}

function Get-KfVersionProperties {
    param([Parameter(Mandatory)][string]$Version)

    $versionCore = ($Version -split '-', 2)[0]
    $parts = @($versionCore -split '\.')
    if ($parts.Count -lt 3) {
        throw "Version must include major, minor, and patch parts: $Version"
    }

    [pscustomobject]@{
        Version = $versionCore
        PackageVersion = $Version
        AssemblyVersion = "$($parts[0]).$($parts[1]).0.0"
        FileVersion = "$($parts[0]).$($parts[1]).$($parts[2]).0"
    }
}

function Invoke-KfClean {
    param([string]$Configuration = 'Debug')

    $repoRoot = Get-KfRepoRoot
    $target = Get-KfBuildTarget -RepoRoot $repoRoot
    $repoArtifacts = Get-KfRepoArtifactPath -RepoRoot $repoRoot -ChildPath ''

    Push-Location $repoRoot
    try {
        Invoke-KfDotNet @('clean', $target, '-c', $Configuration, '--verbosity', 'minimal')
        Remove-Item $repoArtifacts -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item 'out', 'artifacts', 'TestResults', 'coverage-report', 'BenchmarkDotNet.Artifacts' -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Clean complete. Repo artifacts: $repoArtifacts" -ForegroundColor Green
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
    $testResultsPath = Get-KfRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'test-results'

    Push-Location $repoRoot
    try {
        if ($testProjects.Count -eq 0) {
            Write-Host 'No unit test projects found.' -ForegroundColor Yellow
            return
        }

        Ensure-KfLocalNuGetSources -RepoRoot $repoRoot
        Invoke-KfDotNet @('build', $target, '--force', '-c', $Configuration)

        New-Item -Path $testResultsPath -ItemType Directory -Force | Out-Null
        foreach ($project in $testProjects) {
            $logName = "$($project.BaseName)-TestResults.html"
            Invoke-KfDotNet @(
                'test', $project.FullName,
                '-c', $Configuration,
                '--no-build',
                '--filter', 'FullyQualifiedName!~Integration',
                '--logger', "html;LogFileName=$logName",
                '--results-directory', $testResultsPath
            )
        }
        Write-Host "Test results: $testResultsPath" -ForegroundColor Green
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
    $testResultsPath = Get-KfRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'test-results'
    $coveragePath = Get-KfRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'coverage'
    $toolPath = Get-KfRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'tools'

    Push-Location $repoRoot
    try {
        if ($testProjects.Count -eq 0) {
            Write-Host 'No unit test projects found.' -ForegroundColor Yellow
            return
        }

        Ensure-KfLocalNuGetSources -RepoRoot $repoRoot
        Invoke-KfDotNet @('build', $target, '--force', '-c', $Configuration)

        New-Item -Path $testResultsPath -ItemType Directory -Force | Out-Null
        $testArgs = @(
            'test', $target,
            '-c', $Configuration,
            '--no-build',
            '--filter', 'FullyQualifiedName!~Integration',
            '--logger', 'html;LogFilePrefix=TestResults',
            '--results-directory', $testResultsPath,
            '--collect', 'XPlat Code Coverage'
        )

        if (Test-Path 'coverlet.runsettings') {
            $testArgs += @('--settings', 'coverlet.runsettings')
        }

        Invoke-KfDotNet $testArgs

        $coverageFiles = @(Get-ChildItem -Path $testResultsPath -Recurse -File -Filter 'coverage.cobertura.xml' -ErrorAction SilentlyContinue)
        if ($coverageFiles.Count -eq 0) {
            Write-Host 'No Cobertura coverage files were produced.' -ForegroundColor Yellow
            return
        }

        New-Item -Path $coveragePath -ItemType Directory -Force | Out-Null
        $reportArgs = @(
            "-reports:$testResultsPath/**/coverage.cobertura.xml",
            "-targetdir:$coveragePath",
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
            New-Item -Path $toolPath -ItemType Directory -Force | Out-Null
            Invoke-KfDotNet @('tool', 'install', 'dotnet-reportgenerator-globaltool', '--tool-path', $toolPath)
            $reportGenerator = Join-Path $toolPath 'reportgenerator'
            Invoke-KfNativeCommand -FilePath $reportGenerator -Arguments $reportArgs
        }

        $coverageIndex = Join-Path $coveragePath 'index.html'
        if ($Open -and (Test-Path $coverageIndex)) {
            Invoke-Item (Resolve-Path $coverageIndex)
        }

        Write-Host "Coverage report: $coverageIndex" -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Invoke-KfIntegration {
    param([string]$Configuration = 'Debug')

    $repoRoot = Get-KfRepoRoot
    $target = Get-KfBuildTarget -RepoRoot $repoRoot
    $integrationProjects = @(Get-KfTestProjects -RepoRoot $repoRoot -Integration)
    $testResultsPath = Get-KfRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'test-results/integration'

    Push-Location $repoRoot
    try {
        if ($integrationProjects.Count -eq 0) {
            Write-Host 'No integration test projects found.' -ForegroundColor Yellow
            return
        }

        Ensure-KfLocalNuGetSources -RepoRoot $repoRoot
        Invoke-KfDotNet @('build', $target, '--force', '-c', $Configuration)

        New-Item -Path $testResultsPath -ItemType Directory -Force | Out-Null
        foreach ($project in $integrationProjects) {
            $relativeProject = Get-KfRelativePath -RepoRoot $repoRoot -Path $project.FullName
            $logName = "$($project.BaseName).trx"
            Invoke-KfDotNet @(
                'test', $relativeProject,
                '-c', $Configuration,
                '--no-build',
                '--logger', "trx;LogFileName=$logName",
                '--results-directory', $testResultsPath
            )
        }

        Write-Host "Test results: $testResultsPath" -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Invoke-KfBenchmark {
    param([string]$Configuration = 'Release')

    $repoRoot = Get-KfRepoRoot
    $benchmarkProjects = @(Get-KfBenchmarkProjects -RepoRoot $repoRoot)
    $benchmarkPath = Get-KfRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'benchmarks'

    Push-Location $repoRoot
    try {
        if ($benchmarkProjects.Count -eq 0) {
            Write-Host 'No benchmark projects found.' -ForegroundColor Yellow
            return
        }

        New-Item -Path $benchmarkPath -ItemType Directory -Force | Out-Null
        foreach ($project in $benchmarkProjects) {
            $relativeProject = Get-KfRelativePath -RepoRoot $repoRoot -Path $project.FullName
            Invoke-KfDotNet @('run', '--project', $relativeProject, '-c', $Configuration, '--', '--artifacts', $benchmarkPath)
        }

        Write-Host "Benchmark artifacts: $benchmarkPath" -ForegroundColor Green
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
    $packableProjects = @(Get-KfPackableProjects -RepoRoot $repoRoot)
    $packagePath = Get-KfRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'packages'

    Push-Location $repoRoot
    try {
        Ensure-KfLocalNuGetSources -RepoRoot $repoRoot
        New-Item -Path $packagePath -ItemType Directory -Force | Out-Null
        foreach ($project in $packableProjects) {
            $dotnetArgs = @('pack', $project.FullName, '-c', $Configuration, '-o', $packagePath)
            if ($NoBuild) { $dotnetArgs += '--no-build' }
            if ($Version) {
                $versions = Get-KfVersionProperties -Version $Version
                $dotnetArgs += @(
                    "/p:MinVerSkip=true",
                    "/p:Version=$($versions.Version)",
                    "/p:PackageVersion=$($versions.PackageVersion)",
                    "/p:AssemblyVersion=$($versions.AssemblyVersion)",
                    "/p:FileVersion=$($versions.FileVersion)"
                )
            }

            Invoke-KfDotNet -Arguments $dotnetArgs
        }
        Write-Host "Packages written to $packagePath" -ForegroundColor Green
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
    $testResultsPath = Get-KfRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'test-results/release'

    Push-Location $repoRoot
    try {
        Ensure-KfLocalNuGetSources -RepoRoot $repoRoot
        Invoke-KfDotNet @('build', $target, '--force', '-c', 'Release')

        if ($testProjects.Count -gt 0) {
            New-Item -Path $testResultsPath -ItemType Directory -Force | Out-Null
            Invoke-KfDotNet @(
                'test', $target,
                '-c', 'Release',
                '--no-build',
                '--filter', 'FullyQualifiedName!~Integration',
                '--logger', 'html;LogFileName=TestResults.html',
                '--results-directory', $testResultsPath
            )
        }

        Invoke-KfPack -Configuration 'Release' -Version $Version -NoBuild

        $packagePath = Get-KfRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'packages'
        $packages = @(Get-ChildItem -Path $packagePath -Filter '*.nupkg' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.symbols.nupkg' })
        if ($packages.Count -eq 0) {
            throw "No NuGet packages were produced under $packagePath."
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




