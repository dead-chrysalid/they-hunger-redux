[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "StillHunger-Sync-Test-$PID-$([Guid]::NewGuid().ToString('N'))"
)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Write-Utf8 {
    param([string]$Path, [string]$Value)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Invoke-TestGit {
    param([string]$Repository, [string[]]$Arguments)
    $preference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& git -C $Repository @Arguments 2>&1)
        $exit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $preference
    }
    if ($exit -ne 0) {
        throw "Test Git command failed in '$Repository': git $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine).Trim()
}

function Invoke-TestTool {
    param(
        [string]$Command,
        [switch]$ExpectFailure
    )
    $output = @(
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (
            Join-Path $temporaryRoot 'tools\StillHunger.ps1'
        ) $Command -Name 'sync-test' 2>&1
    )
    $exit = $LASTEXITCODE
    $jsonText = $output -join [Environment]::NewLine
    $json = $jsonText | ConvertFrom-Json
    if (-not $json.PSObject.Properties['success']) {
        throw "'$Command' returned unexpected output:`n$jsonText"
    }
    if ($ExpectFailure) {
        Assert-True ($exit -ne 0 -and -not $json.success) "Expected '$Command' to fail."
    }
    else {
        Assert-True ($exit -eq 0 -and $json.success) "'$Command' failed:`n$jsonText"
    }
    return $json
}

function New-MasterCommit {
    param([string]$Repository, [string]$Name)
    Write-Utf8 (Join-Path $Repository "$Name.txt") "$Name`n"
    $null = Invoke-TestGit $Repository @('add', '--', "$Name.txt")
    $null = Invoke-TestGit $Repository @('commit', '-m', $Name)
}

try {
    New-Item -ItemType Directory -Force -Path (
        Join-Path $temporaryRoot 'tools'
    ), (
        Join-Path $temporaryRoot 'repos'
    ), (
        Join-Path $temporaryRoot 'work'
    ) | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tools\StillHunger.ps1') -Destination (
        Join-Path $temporaryRoot 'tools\StillHunger.ps1'
    )
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tools\StillHunger.ContentAudit.ps1') -Destination (
        Join-Path $temporaryRoot 'tools\StillHunger.ContentAudit.ps1'
    )

    $project = [ordered]@{
        schemaVersion = 1
        name = 'StillHunger sync integration test'
        gameToken = 'StillHunger'
        paths = [ordered]@{
            repositories = [ordered]@{
                engine = 'repos/engine'
                sdk = 'repos/sdk'
                rtgl1 = 'repos/rtgl1'
                mainui = 'repos/mainui'
                content = 'repos/content'
            }
            work = 'work'
            preprod = 'runtime/preprod'
            releases = 'releases'
            releaseManifests = 'manifests/releases'
            archives = 'archives'
            production = (Join-Path $temporaryRoot 'production')
        }
        branches = [ordered]@{
            engine = 'master'
            sdk = 'master'
            rtgl1 = 'master'
            mainui = 'master'
            content = 'master'
            featurePrefix = 'codex/'
        }
        api = [ordered]@{ clientDll = 10; renderer = 4 }
        dependencies = [ordered]@{}
        requiredArtifacts = [ordered]@{ engine = @(); sdk = @() }
        releaseExclusions = @()
        userOwned = @()
        initialDefaults = [ordered]@{ root = ''; game = '' }
        development = [ordered]@{
            launchArguments = @('-dev')
            renderer = [ordered]@{ developerMode = $true; developerWindow = $false }
            gameCommands = @('sv_cheats 1')
        }
        distribution = [ordered]@{ optiscaler = '' }
        releasePolicy = [ordered]@{
            campaignMaps = @()
            campaignSmokeSeconds = 1
            valveIncludePatterns = @()
            valveSpriteFiles = @()
            requiredHudEntries = @()
            forbiddenRuntimePatterns = @()
            logFailurePatterns = @()
        }
        build = [ordered]@{
            configuration = 'Release'
            platform = 'x64'
            engineSolution = 'unused.sln'
            engineOutput = 'unused'
            sdkBuild = 'unused'
            rtgl1Build = 'unused'
        }
        smoke = [ordered]@{
            map = 'test'
            seconds = 1
            arguments = @()
        }
    }
    Write-Utf8 (Join-Path $temporaryRoot 'project.json') (
        $project | ConvertTo-Json -Depth 20
    )

    foreach ($component in @('engine', 'sdk', 'rtgl1', 'mainui', 'content')) {
        $repository = Join-Path $temporaryRoot "repos\$component"
        New-Item -ItemType Directory -Force -Path $repository | Out-Null
        $null = Invoke-TestGit $repository @('init', '-b', 'master')
        $null = Invoke-TestGit $repository @('config', 'user.name', 'StillHunger Sync Test')
        $null = Invoke-TestGit $repository @('config', 'user.email', 'sync-test@invalid.local')
        $null = Invoke-TestGit $repository @('config', 'core.autocrlf', 'false')
        Write-Utf8 (Join-Path $repository 'seed.txt') "$component`n"
        if ($component -eq 'engine') {
            Write-Utf8 (Join-Path $repository 'engine\cdll_int.h') "#define CLDLL_INTERFACE_VERSION 10`n"
            Write-Utf8 (Join-Path $repository 'engine\ref_api.h') "#define REF_API_VERSION 4`n"
        }
        if ($component -eq 'sdk') {
            Write-Utf8 (Join-Path $repository 'engine\cdll_int.h') "#define CLDLL_INTERFACE_VERSION 10`n"
        }
        if ($component -eq 'content') {
            Write-Utf8 (Join-Path $repository 'rt\data\scenes.json') "{}`n"
            Write-Utf8 (Join-Path $repository 'rt\data\textures.json') "{}`n"
            Write-Utf8 (Join-Path $repository 'StillHunger\gameinfo.txt') "game StillHunger`n"
            Write-Utf8 (Join-Path $repository 'valve\gameinfo.txt') "game valve`n"
        }
        $null = Invoke-TestGit $repository @('add', '--all')
        $null = Invoke-TestGit $repository @('commit', '-m', 'Seed repository')
    }

    $featureRoot = Join-Path $temporaryRoot 'work\sync-test'
    New-Item -ItemType Directory -Force -Path $featureRoot | Out-Null
    $featurePaths = [ordered]@{}
    foreach ($component in @('engine', 'sdk', 'rtgl1', 'content')) {
        $pathName = if ($component -eq 'content') { 'runtime' } else { $component }
        $path = Join-Path $featureRoot $pathName
        $repository = Join-Path $temporaryRoot "repos\$component"
        $null = Invoke-TestGit $repository @(
            'worktree', 'add', '-b', 'codex/sync-test', $path, 'master'
        )
        $featurePaths[$pathName] = $path
    }
    $feature = [ordered]@{
        schemaVersion = 1
        name = 'sync-test'
        branch = 'codex/sync-test'
        status = 'active'
        createdUtc = [DateTime]::UtcNow.ToString('o')
        paths = [ordered]@{
            engine = $featurePaths.engine
            sdk = $featurePaths.sdk
            rtgl1 = $featurePaths.rtgl1
            runtime = $featurePaths.runtime
        }
    }
    Write-Utf8 (Join-Path $featureRoot 'feature.json') (
        $feature | ConvertTo-Json -Depth 10
    )

    New-MasterCommit (Join-Path $temporaryRoot 'repos\engine') 'engine-master'
    New-MasterCommit (Join-Path $temporaryRoot 'repos\content') 'content-master'
    Write-Utf8 (Join-Path $featurePaths.sdk 'sdk-feature.txt') "feature`n"
    $null = Invoke-TestGit $featurePaths.sdk @('add', '--', 'sdk-feature.txt')
    $null = Invoke-TestGit $featurePaths.sdk @('commit', '-m', 'SDK feature change')
    New-MasterCommit (Join-Path $temporaryRoot 'repos\sdk') 'sdk-master'

    $stateRoot = Join-Path $featureRoot '.state'
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    $initialCommits = [ordered]@{}
    foreach ($component in @('engine', 'sdk', 'rtgl1')) {
        $initialCommits[$component] = Invoke-TestGit $featurePaths.$component @('rev-parse', 'HEAD')
    }
    $initialCommits['content'] = Invoke-TestGit $featurePaths.runtime @('rev-parse', 'HEAD')
    $initialCommits['mainui'] = Invoke-TestGit (Join-Path $temporaryRoot 'repos\mainui') @('rev-parse', 'HEAD')
    Write-Utf8 (Join-Path $stateRoot 'build.json') (
        [ordered]@{
            success = $true
            builtUtc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
            commits = $initialCommits
        } | ConvertTo-Json -Depth 6
    )
    Write-Utf8 (Join-Path $stateRoot 'smoke.json') (
        [ordered]@{
            success = $true
            finishedUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 4
    )

    $before = Invoke-TestTool 'status'
    Assert-True ([bool]$before.result.integration.needsSync) 'Status did not report the feature behind master.'
    Assert-True ([int]$before.result.repositories.engine.integration.behind -eq 1) 'Engine behind count is incorrect.'
    Assert-True (
        [int]$before.result.repositories.sdk.integration.ahead -eq 1 -and
        [int]$before.result.repositories.sdk.integration.behind -eq 1 -and
        [bool]$before.result.repositories.sdk.integration.diverged
    ) 'SDK divergence was not reported correctly.'

    $sync = Invoke-TestTool 'sync'
    Assert-True (@($sync.result.changed).Count -eq 3) 'Sync did not update the three behind components.'
    Assert-True (
        @($sync.result.verificationInvalidated) -contains 'build.json' -and
        @($sync.result.verificationInvalidated) -contains 'smoke.json'
    ) 'Sync did not invalidate stale build and smoke evidence.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'build.json'))) 'Stale build record remains.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $stateRoot 'smoke.json'))) 'Stale smoke record remains.'

    $after = Invoke-TestTool 'status'
    Assert-True (-not [bool]$after.result.integration.needsSync) 'Feature remains behind master after sync.'
    foreach ($component in @('engine', 'sdk', 'rtgl1', 'content')) {
        Assert-True (
            [int]$after.result.repositories.$component.integration.behind -eq 0
        ) "$component remains behind master after sync."
    }
    $noop = Invoke-TestTool 'sync'
    Assert-True ([bool]$noop.result.alreadyCurrent) 'A second sync was not a no-op.'

    $commits = [ordered]@{}
    foreach ($component in @('engine', 'sdk', 'rtgl1')) {
        $commits[$component] = Invoke-TestGit $featurePaths.$component @('rev-parse', 'HEAD')
    }
    $commits['content'] = Invoke-TestGit $featurePaths.runtime @('rev-parse', 'HEAD')
    $commits['mainui'] = Invoke-TestGit (Join-Path $temporaryRoot 'repos\mainui') @('rev-parse', 'HEAD')
    $staleBuiltUtc = [DateTime]::UtcNow.ToString('o')
    Write-Utf8 (Join-Path $stateRoot 'build.json') (
        [ordered]@{ success = $true; builtUtc = $staleBuiltUtc; commits = $commits } |
            ConvertTo-Json -Depth 6
    )
    Write-Utf8 (Join-Path $stateRoot 'smoke.json') (
        [ordered]@{
            success = $true
            finishedUtc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
        } | ConvertTo-Json -Depth 4
    )
    $staleFinish = Invoke-TestTool 'finish' -ExpectFailure
    Assert-True (
        [string]$staleFinish.error -like '*smoke test is older than the current build*'
    ) 'Finish did not reject stale smoke evidence.'

    $builtUtc = [DateTime]::UtcNow.AddMinutes(-1).ToString('o')
    Write-Utf8 (Join-Path $stateRoot 'build.json') (
        [ordered]@{ success = $true; builtUtc = $builtUtc; commits = $commits } |
            ConvertTo-Json -Depth 6
    )
    Write-Utf8 (Join-Path $stateRoot 'smoke.json') (
        [ordered]@{
            success = $true
            finishedUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Depth 4
    )
    New-MasterCommit (Join-Path $temporaryRoot 'repos\engine') 'engine-master-again'
    $finish = Invoke-TestTool 'finish' -ExpectFailure
    Assert-True (
        [string]$finish.error -like '*engine feature is behind master by 1 commit*'
    ) 'Finish did not reject a feature behind master.'

    [ordered]@{
        success = $true
        tests = @(
            'ahead/behind status',
            'diverged feature sync',
            'fast-forward feature sync',
            'verification invalidation',
            'idempotent sync',
            'finish stale-smoke gate',
            'finish behind-master gate'
        )
    } | ConvertTo-Json -Depth 5
}
finally {
    $resolved = [IO.Path]::GetFullPath($temporaryRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
