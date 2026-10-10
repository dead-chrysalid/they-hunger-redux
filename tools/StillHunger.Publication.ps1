# Source-only checkout and builds. Loaded by StillHunger.ps1 through the .cmd entrypoint.
function Get-PublicSourceManifest {
    $file = Join-Path $script:ProjectRoot 'sources.json'
    if (-not (Test-Path -LiteralPath $file)) { throw 'sources.json is missing.' }
    $manifest = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if ([int]$manifest.schemaVersion -ne 1) { throw 'Unsupported source manifest version.' }
    foreach ($component in @('engine', 'sdk', 'rtgl1', 'mainui')) {
        $entry = $manifest.components.$component
        if ([string]$entry.revision -notmatch '^[0-9a-f]{40}$') { throw "Invalid public revision for $component." }
        if ([string]$entry.url -notmatch '^https://github\.com/dead-chrysalid/they-hunger-redux-(engine|sdk|renderer|menu)\.git$') {
            throw "Unexpected public source URL for $component."
        }
    }
    return $manifest
}

function Assert-PublicSourceRevisions {
    $manifest = Get-PublicSourceManifest
    foreach ($component in @('engine', 'sdk', 'rtgl1', 'mainui')) {
        $repo = Get-RepoPath $component
        if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { throw "Missing $component source. Run 'sources' first." }
        if (-not (Test-GitClean $repo)) { throw "The $component source checkout is dirty." }
        $actual = Invoke-Git $repo @('rev-parse', 'HEAD')
        if ($actual -ne [string]$manifest.components.$component.revision) {
            throw "The $component checkout differs from sources.json; preserve your work and use a separate checkout for this source snapshot."
        }
    }
    return $manifest
}

function Invoke-PublicSources {
    Enter-ProjectLock
    $manifest = Get-PublicSourceManifest
    $logRoot = Join-Path $script:ProjectRoot '.state\publication-setup'
    foreach ($component in @('mainui', 'engine', 'sdk', 'rtgl1')) {
        $repo = Get-RepoPath $component
        $entry = $manifest.components.$component
        if (Test-Path -LiteralPath $repo) {
            if (-not (Test-Path -LiteralPath (Join-Path $repo '.git'))) { throw "Existing $component path is not a Git checkout." }
            if (-not (Test-GitClean $repo)) { throw "Existing $component checkout is dirty; refusing to replace it." }
            if ((Invoke-Git $repo @('rev-parse', 'HEAD')) -ne [string]$entry.revision) {
                throw "Existing $component checkout is at another revision; refusing to reset it."
            }
            continue
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $repo) | Out-Null
        Invoke-LoggedGitScript @('clone', '--no-checkout', '--single-branch', '--branch', 'master', '--no-tags', [string]$entry.url, $repo) (Join-Path $logRoot "$component-clone.log")
        $null = Invoke-Git $repo @('checkout', '--detach', [string]$entry.revision)
    }
    Initialize-Submodules (Get-RepoPath 'engine') (Get-RepoPath 'rtgl1') $logRoot
    Invoke-LoggedGitScript @('-C', (Get-RepoPath 'mainui'), 'submodule', 'update', '--init', '--recursive') (Join-Path $logRoot 'menu-submodules.log')
    foreach ($dependency in @('fmt', 'nanorange')) {
        $repo = Resolve-ProjectPath ([string]$script:Project.build.rtgl1LocalSources.$dependency)
        $entry = $manifest.dependencies.$dependency
        if ([string]$entry.revision -notmatch '^[0-9a-f]{40}$') { throw "Invalid revision for $dependency." }
        if (Test-Path -LiteralPath $repo) {
            if (-not (Test-GitClean $repo) -or (Invoke-Git $repo @('rev-parse', 'HEAD')) -ne [string]$entry.revision) {
                throw "Existing $dependency cache differs from sources.json; refusing to replace it."
            }
        }
        else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $repo) | Out-Null
            Invoke-LoggedGitScript @('clone', '--no-checkout', [string]$entry.url, $repo) (Join-Path $logRoot "$dependency-clone.log")
            $null = Invoke-Git $repo @('checkout', '--detach', [string]$entry.revision)
        }
    }
    $null = Assert-PublicSourceRevisions
    return [ordered]@{ components = @('engine', 'sdk', 'rtgl1', 'mainui'); resources = 'ModDB (distributed separately)'; logs = $logRoot }
}

function Invoke-PublicCodeBuild {
    Enter-ProjectLock
    $null = Assert-PublicSourceRevisions
    $paths = [ordered]@{ engine = Get-RepoPath 'engine'; sdk = Get-RepoPath 'sdk'; rtgl1 = Get-RepoPath 'rtgl1' }
    $logs = Join-Path $script:ProjectRoot '.state\publication-build'
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    $api = Assert-ApiCompatible $paths.engine $paths.sdk
    $sdl2 = Resolve-ProjectPath ([string]$script:Project.dependencies.sdl2.path)
    foreach ($required in @('include\SDL.h', 'lib\x64\SDL2.dll', 'lib\x64\SDL2.lib')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sdl2 $required))) { throw "SDL2 2.0.14 development files are missing: $required. See docs/BUILDING.md." }
    }
    Initialize-Submodules $paths.engine $paths.rtgl1 $logs
    $rtglBuild = Join-Path $paths.rtgl1 ([string]$script:Project.build.rtgl1Build -replace '/', '\')
    $configure = @('-S', $paths.rtgl1, '-B', $rtglBuild, '-A', 'x64', '-DRG_WITH_SURFACE_WIN32=ON', '-DRG_WITH_AMD_FSR2=ON', '-DRG_WITH_NVIDIA_DLSS=OFF', '-DRG_WITH_SHADERS=ON', '-DRG_WITH_EDITOR_TESTS=ON', '-DRG_WITH_EXAMPLES=OFF', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5')
    # These exact dependency revisions are provisioned by the sources command.
    foreach ($dependency in @('fmt', 'nanorange')) {
        $source = Resolve-ProjectPath ([string]$script:Project.build.rtgl1LocalSources.$dependency)
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "Missing $dependency source cache. Run 'sources' first." }
        if (-not (Test-GitClean $source) -or (Invoke-Git $source @('rev-parse', 'HEAD')) -ne [string](Get-PublicSourceManifest).dependencies.$dependency.revision) {
            throw "The $dependency dependency differs from sources.json."
        }
        $configure += "-DFETCHCONTENT_SOURCE_DIR_$($dependency.ToUpperInvariant())=$source"
    }
    $configure += '-DFETCHCONTENT_UPDATES_DISCONNECTED=ON'
    Invoke-Logged 'cmake' $configure (Join-Path $logs 'renderer-configure.log')
    $configuration = [string]$script:Project.build.configuration
    Invoke-Logged 'cmake' @('--build', $rtglBuild, '--config', $configuration, '--parallel') (Join-Path $logs 'renderer-build.log')
    Invoke-Logged 'ctest' @('--test-dir', $rtglBuild, '-C', $configuration, '--output-on-failure') (Join-Path $logs 'renderer-tests.log')
    foreach ($extension in @('dll', 'lib')) {
        Copy-Item -LiteralPath (Join-Path $rtglBuild "$configuration\RayTracedGL1.$extension") -Destination (Join-Path $rtglBuild "RayTracedGL1.$extension") -Force
    }
    Invoke-Logged (Find-MSBuild) @((Join-Path $paths.engine ([string]$script:Project.build.engineSolution)), '/m:1', "/p:Configuration=$configuration", '/p:Platform=x64', "/p:RTGL1_SDK_PATH=$($paths.rtgl1)", "/p:XashRtSdl2SdkPath=$sdl2", '/p:XashRtDeployEnabled=false') (Join-Path $logs 'engine-build.log')
    $sdkBuild = Join-Path $paths.sdk ([string]$script:Project.build.sdkBuild -replace '/', '\')
    Invoke-Logged 'cmake' @('-S', $paths.sdk, '-B', $sdkBuild, '-A', 'x64', '-D64BIT=ON') (Join-Path $logs 'sdk-configure.log')
    Invoke-Logged 'cmake' @('--build', $sdkBuild, '--config', $configuration, '--parallel') (Join-Path $logs 'sdk-build.log')
    Invoke-Logged 'ctest' @('--test-dir', $sdkBuild, '-C', $configuration, '--output-on-failure') (Join-Path $logs 'sdk-tests.log')
    $engineOutput = Join-Path $paths.engine ([string]$script:Project.build.engineOutput -replace '/', '\')
    foreach ($artifact in @('xash3d.exe', 'xash.dll', 'filesystem_stdio.dll', 'ref_gl.dll', 'menu.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $engineOutput $artifact))) { throw "Missing engine build artifact: $artifact" }
    }
    foreach ($artifact in @("cl_dll\$configuration\client_amd64.dll", "dlls\$configuration\einar_amd64.dll")) {
        if (-not (Test-Path -LiteralPath (Join-Path $sdkBuild $artifact))) { throw "Missing SDK build artifact: $artifact" }
    }
    return [ordered]@{ api = $api; logs = $logs; engine = $engineOutput; renderer = $rtglBuild; sdk = $sdkBuild; runtimeAssembled = $false }
}
