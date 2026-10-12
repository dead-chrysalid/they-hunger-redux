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
        Invoke-LoggedGitScript -Arguments @('clone', '--no-checkout', '--single-branch', '--branch', 'master', '--no-tags', [string]$entry.url, $repo) -Log (Join-Path $logRoot "$component-clone.log")
        $null = Invoke-Git $repo @('checkout', '--detach', [string]$entry.revision)
    }
    Initialize-Submodules (Get-RepoPath 'engine') (Get-RepoPath 'rtgl1') $logRoot
    Invoke-LoggedGitScript -Arguments @('-C', (Get-RepoPath 'mainui'), 'submodule', 'update', '--init', '--recursive') -Log (Join-Path $logRoot 'menu-submodules.log')
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
            Invoke-LoggedGitScript -Arguments @('clone', '--no-checkout', [string]$entry.url, $repo) -Log (Join-Path $logRoot "$dependency-clone.log")
            $null = Invoke-Git $repo @('checkout', '--detach', [string]$entry.revision)
        }
    }
    $null = Assert-PublicSourceRevisions
    return [ordered]@{ components = @('engine', 'sdk', 'rtgl1', 'mainui'); resources = 'ModDB (distributed separately)'; logs = $logRoot }
}

function Invoke-PublicCodeBuild {
    Enter-ProjectLock
    $null = Assert-PublicSourceRevisions
    $receipt = Join-Path $script:ProjectRoot '.state\publication-build\build.json'
    if (Test-Path -LiteralPath $receipt) { Remove-Item -LiteralPath $receipt }
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
    $msbuild = Find-MSBuild
    # Build the launcher and its complete engine/menu dependency set. The
    # solution's default Build also runs optional tests against private models.
    Invoke-Logged $msbuild @((Join-Path $paths.engine ([string]$script:Project.build.engineSolution)), '/t:xash3d', '/m:1', "/p:Configuration=$configuration", '/p:Platform=x64', "/p:RTGL1_SDK_PATH=$($paths.rtgl1)", "/p:XashRtSdl2SdkPath=$sdl2", '/p:XashRtDeployEnabled=false') (Join-Path $logs 'engine-build.log')
    # Compile/link the same physics test executable without invoking its
    # AfterTargets=Build model-data hook, then run its synthetic test suite.
    Invoke-Logged $msbuild @((Join-Path $paths.engine 'tests\ragdoll_physics_tests.vcxproj'), '/t:BuildCompile;BuildLink', '/m:1', "/p:Configuration=$configuration", '/p:Platform=x64') (Join-Path $logs 'engine-tests-build.log')
    Invoke-Logged (Join-Path $paths.engine "tests\build\$configuration\ragdoll_physics_tests.exe") @() (Join-Path $logs 'engine-tests.log')
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
    $payload = @(Get-PublicBuildPayload)
    Write-JsonAtomic $receipt ([ordered]@{
        sources = (Get-PublicSourceManifest).components
        files = @($payload | ForEach-Object { [ordered]@{ path = $_.relative; sha256 = Get-FileSha256 $_.source } })
    })
    return [ordered]@{ api = $api; logs = $logs; engine = $engineOutput; renderer = $rtglBuild; sdk = $sdkBuild; runtimeAssembled = $false; next = 'assemble -Resources <mod-installation>' }
}

function Get-PublicBuildPayload {
    $configuration = [string]$script:Project.build.configuration
    $engine = Join-Path (Get-RepoPath 'engine') ([string]$script:Project.build.engineOutput)
    $renderer = Join-Path (Get-RepoPath 'rtgl1') ([string]$script:Project.build.rtgl1Build)
    $sdk = Join-Path (Get-RepoPath 'sdk') ([string]$script:Project.build.sdkBuild)
    $sdl = Resolve-ProjectPath ([string]$script:Project.dependencies.sdl2.path)
    foreach ($file in @('xash3d.exe', 'xash.dll', 'filesystem_stdio.dll', 'ref_gl.dll', 'menu.dll')) {
        [pscustomobject]@{ source = Join-Path $engine $file; relative = "rt_bin/$file" }
    }
    [pscustomobject]@{ source = Join-Path $renderer 'RayTracedGL1.dll'; relative = 'rt_bin/RayTracedGL1.dll' }
    [pscustomobject]@{ source = Join-Path $sdl 'lib/x64/SDL2.dll'; relative = 'rt_bin/SDL2.dll' }
    [pscustomobject]@{ source = Join-Path $sdk "cl_dll/$configuration/client_amd64.dll"; relative = "$($script:Project.gameToken)/cl_dlls/client_amd64.dll" }
    [pscustomobject]@{ source = Join-Path $sdk "dlls/$configuration/einar_amd64.dll"; relative = "$($script:Project.gameToken)/dlls/einar_amd64.dll" }
    $shaders = @(Get-ChildItem -LiteralPath (Join-Path $renderer 'shaders') -Filter '*.spv' -File)
    if ($shaders.Count -eq 0) { throw 'Compiled shaders are missing. Run build-code first.' }
    foreach ($file in $shaders) {
        [pscustomobject]@{ source = $file.FullName; relative = "rt/shaders/$($file.Name)" }
    }
}

function Get-PublicRuntimePath {
    param([string]$Output)
    $work = Resolve-ProjectPath ([string]$script:Project.paths.work)
    if ([string]::IsNullOrWhiteSpace($Output)) { $Output = Join-Path $work 'play' }
    if (-not [IO.Path]::IsPathRooted($Output)) { $Output = Join-Path $script:ProjectRoot $Output }
    $resolved = [IO.Path]::GetFullPath($Output).TrimEnd('\', '/')
    if (-not $resolved.StartsWith($work.TrimEnd('\', '/') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Assembly output must be a new directory inside the project work folder.'
    }
    # Reject junctions/symlinks in the destination's ancestors, including work.
    $ancestor = $resolved
    while ($ancestor -and $ancestor -ne $script:ProjectRoot) {
        if (Test-Path -LiteralPath $ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Assembly output uses a junction or symbolic link: $ancestor"
            }
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    return $resolved
}

function Invoke-PublicAssemble {
    param([string]$Resources, [string]$Output)
    Enter-ProjectLock
    $destination = Get-PublicRuntimePath $Output
    if (Test-Path -LiteralPath $destination) { throw 'Output already exists. Choose a new -Output directory.' }
    if ([string]::IsNullOrWhiteSpace($Resources)) { throw 'Specify -Resources with an extracted ModDB release or existing mod installation.' }
    $resourcesRoot = (Resolve-Path -LiteralPath $Resources -ErrorAction Stop).ProviderPath.TrimEnd('\', '/')
    foreach ($pair in @(@($destination, $resourcesRoot), @($resourcesRoot, $destination))) {
        if ($pair[0].Equals($pair[1], [StringComparison]::OrdinalIgnoreCase) -or
            $pair[0].StartsWith($pair[1] + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Resource and output directories must be separate and must not contain each other.'
        }
    }
    $game = [string]$script:Project.gameToken
    foreach ($relative in @("$game/gameinfo.txt", "$game/maps", "$game/models", 'valve/gameinfo.txt', 'rt/data/scenes.json', 'rt/data/textures.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $resourcesRoot $relative))) { throw "Missing mod resources: $relative" }
    }
    $manifest = Assert-PublicSourceRevisions
    $receiptFile = Join-Path $script:ProjectRoot '.state/publication-build/build.json'
    if (-not (Test-Path -LiteralPath $receiptFile)) { throw 'No successful build recorded. Run build-code first.' }
    $receipt = Get-Content -LiteralPath $receiptFile -Raw | ConvertFrom-Json
    foreach ($component in @('engine', 'sdk', 'rtgl1', 'mainui')) {
        if ($receipt.sources.$component.revision -ne $manifest.components.$component.revision) { throw 'Source revisions changed since the build. Run build-code again.' }
    }
    $payload = @(Get-PublicBuildPayload)
    if ($receipt.files.Count -ne $payload.Count) { throw 'Build output changed. Run build-code again.' }
    foreach ($file in $payload) {
        $record = @($receipt.files | Where-Object { $_.path -eq $file.relative })
        if ($record.Count -ne 1 -or -not (Test-Path -LiteralPath $file.source -PathType Leaf) -or
            (Get-FileSha256 $file.source) -ne $record[0].sha256) { throw "Build output changed: $($file.relative). Run build-code again." }
    }
    # Enumerate before creating output and refuse links rather than following them.
    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($resourcesRoot)
    $resourceFiles = [Collections.Generic.List[object]]::new()
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        if ((Get-Item -LiteralPath $directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Resources contain a junction or symbolic link: $directory" }
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
            $relative = $item.FullName.Substring($resourcesRoot.Length + 1).Replace('\', '/')
            if ((Test-Excluded $relative) -or $relative -eq 'rt/shaders' -or $relative -like 'rt/shaders/*' -or
                $relative -eq 'StartGame.cmd' -or $relative -eq 'source-build.json') { continue }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Resources contain a junction or symbolic link: $relative" }
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName) }
            else { $resourceFiles.Add([pscustomobject]@{ source = $item.FullName; relative = $relative }) }
        }
    }
    $work = Resolve-ProjectPath ([string]$script:Project.paths.work)
    $staging = Get-PublicRuntimePath (Join-Path $work ('.assembling-' + [Guid]::NewGuid().ToString('N')))
    try {
        New-Item -ItemType Directory -Path $staging | Out-Null
        foreach ($file in @($resourceFiles.ToArray()) + $payload) {
            $target = Join-Path $staging $file.relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $file.source -Destination $target -Force
        }
        $launcher = "@echo off`r`ncd /d `"%~dp0`"`r`n`"rt_bin\xash3d.exe`" -game $game %*`r`n"
        [IO.File]::WriteAllText((Join-Path $staging 'StartGame.cmd'), $launcher, [Text.Encoding]::ASCII)
        Copy-Item -LiteralPath $receiptFile -Destination (Join-Path $staging 'source-build.json')
        $state = Test-Runtime $staging
        if (-not $state.valid) { throw "Assembled runtime is incomplete: $($state.missing -join ', ')" }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        $null = Get-PublicRuntimePath $destination
        [IO.Directory]::Move($staging, $destination)
    }
    finally {
        if (Test-Path -LiteralPath $staging) {
            $checked = Get-PublicRuntimePath $staging
            Remove-Item -LiteralPath $checked -Recurse -Force
        }
    }
    return [ordered]@{ runtime = $destination; launcher = Join-Path $destination 'StartGame.cmd'; copiedResources = $resourceFiles.Count; buildFiles = $payload.Count }
}
