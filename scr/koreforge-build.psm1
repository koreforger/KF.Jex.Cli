Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-KoreForgeRepoRoot {
    (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Get-KoreForgeWorkspaceRoot {
    param([Parameter(Mandatory)][string]$RepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($env:KOREFORGE_WORKSPACE_ROOT) -and (Test-Path $env:KOREFORGE_WORKSPACE_ROOT)) {
        return (Resolve-Path $env:KOREFORGE_WORKSPACE_ROOT).Path
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

function Get-KoreForgeArtifactRoot {
    param([Parameter(Mandatory)][string]$RepoRoot)

    if (-not [string]::IsNullOrWhiteSpace($env:KOREFORGE_ARTIFACTS_ROOT)) {
        return $env:KOREFORGE_ARTIFACTS_ROOT
    }

    return Join-Path (Get-KoreForgeWorkspaceRoot -RepoRoot $RepoRoot) 'artifacts'
}

function Get-KoreForgeRepoArtifactPath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string]$ChildPath
    )

    $repoName = Split-Path $RepoRoot -Leaf
    $basePath = Join-Path (Get-KoreForgeArtifactRoot -RepoRoot $RepoRoot) (Join-Path 'repos' $repoName)
    if ([string]::IsNullOrEmpty($ChildPath)) { return $basePath }
    return Join-Path $basePath $ChildPath
}

function Get-KoreForgeBuildTarget {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $solutionX = Get-ChildItem -Path $RepoRoot -Filter '*.slnx' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
    if ($solutionX) { return $solutionX.FullName }

    $project = Get-ChildItem -Path $RepoRoot -Filter '*.csproj' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
    if ($project) { return $project.FullName }

    throw "No .slnx or root .csproj build target found in $RepoRoot."
}

function Ensure-KoreForgeLocalNuGetSources {
    param([Parameter(Mandatory)][string]$RepoRoot)

    $workspaceRoot = Get-KoreForgeWorkspaceRoot -RepoRoot $RepoRoot
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

function Invoke-KoreForgeDotNet {
    param([Parameter(Mandatory)][string[]]$Arguments)

    if ([string]::IsNullOrWhiteSpace($env:NUGET_PACKAGES)) {
        $nugetCacheRoot = Join-Path (Get-KoreForgeArtifactRoot -RepoRoot (Get-KoreForgeRepoRoot)) 'nuget-cache'
        $env:NUGET_PACKAGES = $nugetCacheRoot
    }

    $effectiveArguments = @($Arguments)
    if ($effectiveArguments.Count -gt 0 -and $effectiveArguments[0] -in @('build', 'test', 'pack', 'clean')) {
        $repoRoot = (Get-Location).Path
        $buildRoot = Get-KoreForgeRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'build'
        $effectiveArguments += @('--artifacts-path', $buildRoot)
    }

    Write-Host "dotnet $($effectiveArguments -join ' ')" -ForegroundColor DarkCyan
    & dotnet @effectiveArguments
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet command failed with exit code ${LASTEXITCODE}: dotnet $($effectiveArguments -join ' ')"
    }
}

function Invoke-KoreForgeNativeCommand {
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

function Get-KoreForgeRelativePath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path
    )

    return [System.IO.Path]::GetRelativePath($RepoRoot, $Path).Replace('/', '\')
}

function Get-KoreForgeProjectFiles {
    param([Parameter(Mandatory)][string]$RepoRoot)

    Get-ChildItem -Path $RepoRoot -Filter '*.csproj' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } |
        Sort-Object FullName
}

function Test-KoreForgeProjectContains {
    param(
        [Parameter(Mandatory)][System.IO.FileInfo]$Project,
        [Parameter(Mandatory)][string]$Pattern
    )

    return [bool](Select-String -Path $Project.FullName -Pattern $Pattern -Quiet -SimpleMatch)
}

function Get-KoreForgeTestProjects {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Integration
    )

    Get-KoreForgeProjectFiles -RepoRoot $RepoRoot |
        Where-Object { Test-KoreForgeProjectContains -Project $_ -Pattern 'Microsoft.NET.Test.Sdk' } |
        Where-Object {
            $isIntegration = $_.BaseName -match 'Integration'
            if ($Integration) { $isIntegration } else { -not $isIntegration }
        }
}

function Get-KoreForgeBenchmarkProjects {
    param([Parameter(Mandatory)][string]$RepoRoot)

    Get-KoreForgeProjectFiles -RepoRoot $RepoRoot |
        Where-Object { $_.BaseName -match 'Benchmark' -or (Test-KoreForgeProjectContains -Project $_ -Pattern 'BenchmarkDotNet') }
}

function Get-KoreForgePackableProjects {
    param([Parameter(Mandatory)][string]$RepoRoot)

    Get-KoreForgeProjectFiles -RepoRoot $RepoRoot |
        Where-Object { -not (Test-KoreForgeProjectContains -Project $_ -Pattern '<IsPackable>false</IsPackable>') } |
        Where-Object { -not (Test-KoreForgeProjectContains -Project $_ -Pattern 'Microsoft.NET.Test.Sdk') } |
        Where-Object { $_.FullName -notmatch '\\(templates?|samples?|benchmarks?)\\' }
}

function Get-KoreForgeVersionProperties {
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

function Invoke-KoreForgeClean {
    param([string]$Configuration = 'Debug')

    $repoRoot = Get-KoreForgeRepoRoot
    $target = Get-KoreForgeBuildTarget -RepoRoot $repoRoot
    $repoArtifacts = Get-KoreForgeRepoArtifactPath -RepoRoot $repoRoot

    Push-Location $repoRoot
    try {
        Invoke-KoreForgeDotNet @('clean', $target, '-c', $Configuration, '--verbosity', 'minimal')
        Remove-Item $repoArtifacts -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item 'out', 'artifacts', 'TestResults', 'coverage-report', 'BenchmarkDotNet.Artifacts' -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Clean complete. Repo artifacts: $repoArtifacts" -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Invoke-KoreForgeRebuild {
    param([string]$Configuration = 'Debug')

    $repoRoot = Get-KoreForgeRepoRoot
    $target = Get-KoreForgeBuildTarget -RepoRoot $repoRoot

    Push-Location $repoRoot
    try {
        Ensure-KoreForgeLocalNuGetSources -RepoRoot $repoRoot
        Invoke-KoreForgeDotNet @('build', $target, '--force', '-c', $Configuration)
        Write-Host 'Rebuild complete.' -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Invoke-KoreForgeTest {
    param([string]$Configuration = 'Debug')

    $repoRoot = Get-KoreForgeRepoRoot
    $target = Get-KoreForgeBuildTarget -RepoRoot $repoRoot
    $testProjects = @(Get-KoreForgeTestProjects -RepoRoot $repoRoot)
    $testResultsPath = Get-KoreForgeRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'test-results'

    Push-Location $repoRoot
    try {
        if ($testProjects.Count -eq 0) {
            Write-Host 'No unit test projects found.' -ForegroundColor Yellow
            return
        }

        Ensure-KoreForgeLocalNuGetSources -RepoRoot $repoRoot
        Invoke-KoreForgeDotNet @('build', $target, '--force', '-c', $Configuration)

        New-Item -Path $testResultsPath -ItemType Directory -Force | Out-Null
        foreach ($project in $testProjects) {
            $logName = "$($project.BaseName)-TestResults.html"
            Invoke-KoreForgeDotNet @(
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

function Invoke-KoreForgeCoverage {
    param(
        [string]$Configuration = 'Debug',
        [switch]$Open
    )

    $repoRoot = Get-KoreForgeRepoRoot
    $target = Get-KoreForgeBuildTarget -RepoRoot $repoRoot
    $testProjects = @(Get-KoreForgeTestProjects -RepoRoot $repoRoot)
    $testResultsPath = Get-KoreForgeRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'test-results'
    $coveragePath = Get-KoreForgeRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'coverage'
    $toolPath = Get-KoreForgeRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'tools'

    Push-Location $repoRoot
    try {
        if ($testProjects.Count -eq 0) {
            Write-Host 'No unit test projects found.' -ForegroundColor Yellow
            return
        }

        Ensure-KoreForgeLocalNuGetSources -RepoRoot $repoRoot
        Invoke-KoreForgeDotNet @('build', $target, '--force', '-c', $Configuration)

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

        Invoke-KoreForgeDotNet $testArgs

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
            New-Item -Path $toolPath -ItemType Directory -Force | Out-Null
            $manifestVer = ((Get-Content '.config/dotnet-tools.json' | ConvertFrom-Json).tools.'dotnet-reportgenerator-globaltool').version
            $updateArgs = @('tool', 'update', 'dotnet-reportgenerator-globaltool', '--tool-path', $toolPath)
            if ($manifestVer) { $updateArgs += @('--version', $manifestVer) }
            Invoke-KoreForgeDotNet $updateArgs
            Invoke-KoreForgeNativeCommand -FilePath (Join-Path $toolPath 'reportgenerator') -Arguments $reportArgs
        }
        elseif (Get-Command reportgenerator -ErrorAction SilentlyContinue) {
            Invoke-KoreForgeNativeCommand -FilePath 'reportgenerator' -Arguments $reportArgs
        }
        else {
            New-Item -Path $toolPath -ItemType Directory -Force | Out-Null
            Invoke-KoreForgeDotNet @('tool', 'install', 'dotnet-reportgenerator-globaltool', '--tool-path', $toolPath)
            $reportGenerator = Join-Path $toolPath 'reportgenerator'
            Invoke-KoreForgeNativeCommand -FilePath $reportGenerator -Arguments $reportArgs
        }

        $coverageIndex = Join-Path $coveragePath 'index.html'
        if ($Open -and (Test-Path $coverageIndex)) {
            Invoke-Item (Resolve-Path $coverageIndex)
        }

        Write-Host "Coverage report: $coverageIndex" -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Invoke-KoreForgeIntegration {
    param([string]$Configuration = 'Debug')

    $repoRoot = Get-KoreForgeRepoRoot
    $target = Get-KoreForgeBuildTarget -RepoRoot $repoRoot
    $integrationProjects = @(Get-KoreForgeTestProjects -RepoRoot $repoRoot -Integration)
    $testResultsPath = Get-KoreForgeRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'test-results/integration'

    Push-Location $repoRoot
    try {
        if ($integrationProjects.Count -eq 0) {
            Write-Host 'No integration test projects found.' -ForegroundColor Yellow
            return
        }

        Ensure-KoreForgeLocalNuGetSources -RepoRoot $repoRoot
        Invoke-KoreForgeDotNet @('build', $target, '--force', '-c', $Configuration)

        New-Item -Path $testResultsPath -ItemType Directory -Force | Out-Null
        foreach ($project in $integrationProjects) {
            $relativeProject = Get-KoreForgeRelativePath -RepoRoot $repoRoot -Path $project.FullName
            $logName = "$($project.BaseName).trx"
            Invoke-KoreForgeDotNet @(
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

function Invoke-KoreForgeBenchmark {
    param([string]$Configuration = 'Release')

    $repoRoot = Get-KoreForgeRepoRoot
    $benchmarkProjects = @(Get-KoreForgeBenchmarkProjects -RepoRoot $repoRoot)
    $benchmarkPath = Get-KoreForgeRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'benchmarks'

    Push-Location $repoRoot
    try {
        if ($benchmarkProjects.Count -eq 0) {
            Write-Host 'No benchmark projects found.' -ForegroundColor Yellow
            return
        }

        New-Item -Path $benchmarkPath -ItemType Directory -Force | Out-Null
        foreach ($project in $benchmarkProjects) {
            $relativeProject = Get-KoreForgeRelativePath -RepoRoot $repoRoot -Path $project.FullName
            Invoke-KoreForgeDotNet @('run', '--project', $relativeProject, '-c', $Configuration, '--', '--artifacts', $benchmarkPath)
        }

        Write-Host "Benchmark artifacts: $benchmarkPath" -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Invoke-KoreForgePack {
    param(
        [string]$Configuration = 'Release',
        [string]$Version,
        [switch]$NoBuild
    )

    $repoRoot = Get-KoreForgeRepoRoot
    $packableProjects = @(Get-KoreForgePackableProjects -RepoRoot $repoRoot)
    $packagePath = Get-KoreForgeRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'packages'

    Push-Location $repoRoot
    try {
        Ensure-KoreForgeLocalNuGetSources -RepoRoot $repoRoot
        New-Item -Path $packagePath -ItemType Directory -Force | Out-Null
        foreach ($project in $packableProjects) {
            $componentBinRoot = Join-Path (Get-KoreForgeRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'build') 'bin'
            $dotnetArgs = @('pack', $project.FullName, '-c', $Configuration, '-o', $packagePath, "/p:KoreForgeComponentBinRoot=$componentBinRoot", "/p:KoreForgeArtifactsConfiguration=$($Configuration.ToLowerInvariant())")
            if ($NoBuild) { $dotnetArgs += '--no-build' }
            if ($Version) {
                $versions = Get-KoreForgeVersionProperties -Version $Version
                $dotnetArgs += @(
                    "/p:MinVerSkip=true",
                    "/p:Version=$($versions.Version)",
                    "/p:PackageVersion=$($versions.PackageVersion)",
                    "/p:AssemblyVersion=$($versions.AssemblyVersion)",
                    "/p:FileVersion=$($versions.FileVersion)"
                )
            }

            Invoke-KoreForgeDotNet -Arguments $dotnetArgs
        }
        Write-Host "Packages written to $packagePath" -ForegroundColor Green
    }
    finally { Pop-Location }
}

function Get-KoreForgeNuGetReleaseTagPrefix {
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

function Invoke-KoreForgeReleaseNuGetFromGitHub {
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$Note,
        [switch]$Force,
        [switch]$AllowDirty
    )

    $repoRoot = Get-KoreForgeRepoRoot
    Push-Location $repoRoot
    try {
        if (-not $AllowDirty -and (git status --porcelain)) {
            throw 'The repository has uncommitted changes. Commit or stash them before creating a release tag, or pass -AllowDirty explicitly.'
        }

        $tag = (Get-KoreForgeNuGetReleaseTagPrefix -RepoRoot $repoRoot) + $Version
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

function Invoke-KoreForgeReleaseNuGetFromLocal {
    param(
        [Parameter(Mandatory)][string]$Version,
        [string]$ApiKey = $env:NUGET_API_KEY,
        [string]$Source = 'https://api.nuget.org/v3/index.json',
        [switch]$SkipDuplicate
    )

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw 'NuGet API key is required. Pass -ApiKey or set NUGET_API_KEY.'
    }

    $repoRoot = Get-KoreForgeRepoRoot
    $target = Get-KoreForgeBuildTarget -RepoRoot $repoRoot
    $testProjects = @(Get-KoreForgeTestProjects -RepoRoot $repoRoot)
    $testResultsPath = Get-KoreForgeRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'test-results/release'

    Push-Location $repoRoot
    try {
        Ensure-KoreForgeLocalNuGetSources -RepoRoot $repoRoot
        Invoke-KoreForgeDotNet @('build', $target, '--force', '-c', 'Release')

        if ($testProjects.Count -gt 0) {
            New-Item -Path $testResultsPath -ItemType Directory -Force | Out-Null
            Invoke-KoreForgeDotNet @(
                'test', $target,
                '-c', 'Release',
                '--no-build',
                '--filter', 'FullyQualifiedName!~Integration',
                '--logger', 'html;LogFileName=TestResults.html',
                '--results-directory', $testResultsPath
            )
        }

        Invoke-KoreForgePack -Configuration 'Release' -Version $Version -NoBuild

        $packagePath = Get-KoreForgeRepoArtifactPath -RepoRoot $repoRoot -ChildPath 'packages'
        $packages = @(Get-ChildItem -Path $packagePath -Filter '*.nupkg' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.symbols.nupkg' })
        if ($packages.Count -eq 0) {
            throw "No NuGet packages were produced under $packagePath."
        }

        foreach ($package in $packages) {
            $pushArgs = @('nuget', 'push', $package.FullName, '--api-key', $ApiKey, '--source', $Source)
            if ($SkipDuplicate) { $pushArgs += '--skip-duplicate' }
            Invoke-KoreForgeDotNet $pushArgs
        }

        Write-Host "Released $($packages.Count) package(s) from local build." -ForegroundColor Green
    }
    finally { Pop-Location }
}




