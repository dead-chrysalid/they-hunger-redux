[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet(
        'new',
        'status',
        'build',
        'launch-feature',
        'smoke-feature',
        'finish',
        'launch-preprod',
        'smoke-preprod',
        'promote',
        'smoke-production',
        'rollback'
    )]
    [string]$Command,

    [string]$Name,
    [string]$Release,
    [switch]$Screenshots
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:ProjectFile = Join-Path $script:ProjectRoot 'project.json'
$script:Project = Get-Content -LiteralPath $script:ProjectFile -Raw | ConvertFrom-Json
$script:LockStream = $null

function Resolve-ProjectPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Path))
}

function Assert-ProjectPath {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path)
    $prefix = $script:ProjectRoot.TrimEnd('\') + '\'
    if ($resolved -ne $script:ProjectRoot -and
        -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the project: $resolved"
    }
    return $resolved
}

function Get-RepoPath {
    param([Parameter(Mandatory)][string]$Component)
    $relative = $script:Project.paths.repositories.$Component
    if (-not $relative) { throw "Unknown component: $Component" }
    return Resolve-ProjectPath $relative
}

function Require-FeatureName {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "-Name is required for '$Command'."
    }
    if ($Name -notmatch '^[a-z0-9][a-z0-9._-]*$') {
        throw "Feature names may contain lowercase letters, numbers, dots, underscores, and hyphens."
    }
}

function Get-FeatureRoot {
    param([Parameter(Mandatory)][string]$FeatureName)
    return Assert-ProjectPath (Join-Path (Resolve-ProjectPath $script:Project.paths.work) $FeatureName)
}

function Get-Feature {
    param([Parameter(Mandatory)][string]$FeatureName)
    $root = Get-FeatureRoot $FeatureName
    $file = Join-Path $root 'feature.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "Feature '$FeatureName' does not exist."
    }
    return Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )
    $resolved = [IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $resolved
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = "$resolved.tmp-$PID"
    $json = $Value | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $resolved -Force
}

function Enter-ProjectLock {
    $state = Assert-ProjectPath (Join-Path $script:ProjectRoot '.state')
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    $lock = Join-Path $state 'operation.lock'
    try {
        $script:LockStream = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    }
    catch {
        throw "Another project operation is active, or '$lock' is stale."
    }
    $payload = [Text.Encoding]::UTF8.GetBytes(
        ([ordered]@{
            pid = $PID
            command = $Command
            startedUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Compress)
    )
    $script:LockStream.Write($payload, 0, $payload.Length)
    $script:LockStream.Flush()
}

function Exit-ProjectLock {
    if ($script:LockStream) {
        $lock = $script:LockStream.Name
        $script:LockStream.Dispose()
        $script:LockStream = $null
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string[]]$Arguments
    )
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
        throw "Git failed in '$Repository': git $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine).Trim()
}

function Invoke-Logged {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Log
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Log) | Out-Null
    $preference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $Executable @Arguments 2>&1)
        $exit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $preference
    }
    $output | Out-File -LiteralPath $Log -Encoding utf8
    if ($exit -ne 0) {
        $tail = $output | Select-Object -Last 40
        throw "'$Executable' failed with exit code $exit. Log: $Log`n$($tail -join [Environment]::NewLine)"
    }
}

function Test-GitClean {
    param([Parameter(Mandatory)][string]$Repository)
    $status = Invoke-Git $Repository @('status', '--porcelain', '--untracked-files=normal')
    return [string]::IsNullOrWhiteSpace($status)
}

function Get-Reversed {
    param([Parameter(Mandatory)]$Items)
    $array = @($Items)
    [Array]::Reverse($array)
    return $array
}

function Get-GitInfo {
    param([Parameter(Mandatory)][string]$Repository)
    $branch = Invoke-Git $Repository @('branch', '--show-current')
    $commit = Invoke-Git $Repository @('rev-parse', 'HEAD')
    $status = Invoke-Git $Repository @('status', '--porcelain', '--untracked-files=normal')
    return [ordered]@{
        path = $Repository
        branch = $branch
        commit = $commit
        dirty = -not [string]::IsNullOrWhiteSpace($status)
        changes = if ($status) { @($status -split "`r?`n") } else { @() }
    }
}

function Get-ApiState {
    param(
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][string]$Sdk
    )
    $engineClient = Get-Content -LiteralPath (Join-Path $Engine 'engine\cdll_int.h') -Raw
    $sdkClient = Get-Content -LiteralPath (Join-Path $Sdk 'engine\cdll_int.h') -Raw
    $renderer = Get-Content -LiteralPath (Join-Path $Engine 'engine\ref_api.h') -Raw
    $clientExpected = [int]$script:Project.api.clientDll
    $rendererExpected = [int]$script:Project.api.renderer
    $engineClientValue = [int]([regex]::Match($engineClient, 'CLDLL_INTERFACE_VERSION\s+(\d+)').Groups[1].Value)
    $sdkClientValue = [int]([regex]::Match($sdkClient, 'CLDLL_INTERFACE_VERSION\s+(\d+)').Groups[1].Value)
    $rendererValue = [int]([regex]::Match($renderer, 'REF_API_VERSION\s+(\d+)').Groups[1].Value)
    return [ordered]@{
        expectedClient = $clientExpected
        engineClient = $engineClientValue
        sdkClient = $sdkClientValue
        expectedRenderer = $rendererExpected
        renderer = $rendererValue
        compatible = (
            $engineClientValue -eq $clientExpected -and
            $sdkClientValue -eq $clientExpected -and
            $rendererValue -eq $rendererExpected
        )
    }
}

function Assert-ApiCompatible {
    param(
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][string]$Sdk
    )
    $state = Get-ApiState $Engine $Sdk
    if (-not $state.compatible) {
        throw "API mismatch. Expected client $($state.expectedClient) and renderer $($state.expectedRenderer); engine client=$($state.engineClient), SDK client=$($state.sdkClient), renderer=$($state.renderer)."
    }
    return $state
}

function Get-HashInventory {
    param([Parameter(Mandatory)][string]$Root)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return @(
        Get-ChildItem -LiteralPath $rootPath -Recurse -Force -File |
            Sort-Object FullName |
            ForEach-Object {
                [ordered]@{
                    path = $_.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
                    length = $_.Length
                    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
    )
}

function Test-Excluded {
    param([Parameter(Mandatory)][string]$RelativePath)
    $relative = $RelativePath.Replace('\', '/')
    foreach ($pattern in $script:Project.releaseExclusions) {
        if ([WildcardPattern]::new([string]$pattern, [WildcardOptions]::IgnoreCase).IsMatch($relative)) {
            return $true
        }
    }
    return $false
}

function Test-UserOwned {
    param([Parameter(Mandatory)][string]$RelativePath)
    $relative = $RelativePath.Replace('\', '/')
    foreach ($pattern in $script:Project.userOwned) {
        if ([WildcardPattern]::new([string]$pattern, [WildcardOptions]::IgnoreCase).IsMatch($relative)) {
            return $true
        }
    }
    return $false
}

function Copy-Tree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $null = & robocopy $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) {
        throw "Copy failed from '$Source' to '$Destination' (robocopy $LASTEXITCODE)."
    }
}

function Copy-DeployableTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $sourceRoot = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File) {
        $relative = $file.FullName.Substring($sourceRoot.Length + 1)
        if (Test-Excluded $relative) { continue }
        $target = Join-Path $Destination $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}

function Find-MSBuild {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio vswhere.exe was not found.' }
    $path = @(& $vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>&1) |
        Select-Object -First 1
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { throw 'MSBuild.exe was not found.' }
    return [string]$path
}

function Initialize-Submodules {
    param(
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][string]$Rtgl1,
        [Parameter(Mandatory)][string]$LogRoot
    )
    $mainui = Get-RepoPath 'mainui'
    Invoke-Logged 'git' @(
        '-C', $Engine,
        '-c', 'protocol.file.allow=always',
        '-c', "submodule.mainui.url=$($mainui.Replace('\', '/'))",
        'submodule', 'update', '--init', '--recursive'
    ) (Join-Path $LogRoot 'engine-submodules.log')
    Invoke-Logged 'git' @(
        '-C', $Rtgl1,
        'submodule', 'update', '--init', '--recursive'
    ) (Join-Path $LogRoot 'rtgl1-submodules.log')
}

function Copy-InitialDefaults {
    param([Parameter(Mandatory)][string]$Runtime)
    $rootDefaults = Join-Path $Runtime '.workspace\defaults\root'
    $gameDefaults = Join-Path $Runtime '.workspace\defaults\StillHunger'
    foreach ($file in Get-ChildItem -LiteralPath $rootDefaults -Recurse -File) {
        $relative = $file.FullName.Substring($rootDefaults.Length + 1)
        $target = Join-Path $Runtime $relative
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $gameDefaults -Recurse -File) {
        $relative = $file.FullName.Substring($gameDefaults.Length + 1)
        $target = Join-Path (Join-Path $Runtime $script:Project.gameToken) $relative
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target
        }
    }
}

function Install-OptiScaler {
    param([Parameter(Mandatory)][string]$Runtime)
    $distribution = Join-Path $Runtime '.workspace\distribution\optiscaler-0.9.4'
    $rtBin = Join-Path $Runtime 'rt_bin'
    New-Item -ItemType Directory -Force -Path $rtBin | Out-Null
    foreach ($file in Get-ChildItem -LiteralPath $distribution -Recurse -File) {
        $relative = $file.FullName.Substring($distribution.Length + 1)
        if ($relative.Replace('\', '/') -like 'provenance/*' -or $relative -eq 'README.md') { continue }
        $target = Join-Path $rtBin $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        if ($relative -ieq 'OptiScaler.ini' -and (Test-Path -LiteralPath $target)) { continue }
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}

function Get-BuildPaths {
    param([Parameter(Mandatory)]$Feature)
    return [ordered]@{
        engine = [IO.Path]::GetFullPath([string]$Feature.paths.engine)
        sdk = [IO.Path]::GetFullPath([string]$Feature.paths.sdk)
        rtgl1 = [IO.Path]::GetFullPath([string]$Feature.paths.rtgl1)
        runtime = [IO.Path]::GetFullPath([string]$Feature.paths.runtime)
    }
}

function Invoke-BuildSet {
    param(
        [Parameter(Mandatory)]$Paths,
        [Parameter(Mandatory)][string]$StateRoot
    )
    $configuration = [string]$script:Project.build.configuration
    $platform = [string]$script:Project.build.platform
    $logs = Join-Path $StateRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    $api = Assert-ApiCompatible $Paths.engine $Paths.sdk
    Initialize-Submodules $Paths.engine $Paths.rtgl1 $logs

    $rtglBuild = Join-Path $Paths.rtgl1 ($script:Project.build.rtgl1Build -replace '/', '\')
    Invoke-Logged 'cmake' @(
        '-S', $Paths.rtgl1,
        '-B', $rtglBuild,
        '-A', 'x64',
        '-DRG_WITH_AMD_FSR2=ON',
        '-DRG_WITH_SHADERS=ON',
        '-DRG_WITH_EDITOR_TESTS=ON',
        '-DRG_WITH_EXAMPLES=OFF'
    ) (Join-Path $logs 'rtgl1-configure.log')
    Invoke-Logged 'cmake' @(
        '--build', $rtglBuild,
        '--config', $configuration,
        '--parallel'
    ) (Join-Path $logs 'rtgl1-build.log')
    Invoke-Logged 'ctest' @(
        '--test-dir', $rtglBuild,
        '-C', $configuration,
        '--output-on-failure'
    ) (Join-Path $logs 'rtgl1-tests.log')

    $rtglConfigOutput = Join-Path $rtglBuild $configuration
    foreach ($extension in @('dll', 'lib')) {
        $source = Join-Path $rtglConfigOutput "RayTracedGL1.$extension"
        if (-not (Test-Path -LiteralPath $source)) { throw "Missing renderer build artifact: $source" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $rtglBuild "RayTracedGL1.$extension") -Force
    }

    $msbuild = Find-MSBuild
    $sdl2 = Resolve-ProjectPath $script:Project.dependencies.sdl2.path
    $solution = Join-Path $Paths.engine $script:Project.build.engineSolution
    Invoke-Logged $msbuild @(
        $solution,
        '/m',
        "/p:Configuration=$configuration",
        "/p:Platform=$platform",
        "/p:RTGL1_SDK_PATH=$($Paths.rtgl1)",
        "/p:XashRtSdl2SdkPath=$sdl2",
        '/p:XashRtDeployEnabled=false'
    ) (Join-Path $logs 'engine-build.log')

    $sdkBuild = Join-Path $Paths.sdk ($script:Project.build.sdkBuild -replace '/', '\')
    Invoke-Logged 'cmake' @(
        '-S', $Paths.sdk,
        '-B', $sdkBuild,
        '-A', 'x64'
    ) (Join-Path $logs 'sdk-configure.log')
    Invoke-Logged 'cmake' @(
        '--build', $sdkBuild,
        '--config', $configuration,
        '--parallel'
    ) (Join-Path $logs 'sdk-build.log')

    $valve = Resolve-ProjectPath $script:Project.dependencies.valve.path
    Copy-Tree $valve (Join-Path $Paths.runtime 'valve')
    Copy-InitialDefaults $Paths.runtime
    Install-OptiScaler $Paths.runtime

    $rtBin = Join-Path $Paths.runtime 'rt_bin'
    New-Item -ItemType Directory -Force -Path $rtBin | Out-Null
    $engineOutput = Join-Path $Paths.engine ($script:Project.build.engineOutput -replace '/', '\')
    foreach ($artifact in @('xash3d.exe', 'xash.dll', 'filesystem_stdio.dll', 'ref_gl.dll', 'menu.dll')) {
        $source = Join-Path $engineOutput $artifact
        if (-not (Test-Path -LiteralPath $source)) { throw "Missing engine artifact: $source" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $rtBin $artifact) -Force
    }
    Copy-Item -LiteralPath (Join-Path $rtglBuild 'RayTracedGL1.dll') -Destination (Join-Path $rtBin 'RayTracedGL1.dll') -Force
    Copy-Item -LiteralPath (Join-Path $sdl2 'lib\x64\SDL2.dll') -Destination (Join-Path $rtBin 'SDL2.dll') -Force

    $client = Join-Path $sdkBuild "cl_dll\$configuration\client_amd64.dll"
    $server = Join-Path $sdkBuild "dlls\$configuration\einar_amd64.dll"
    foreach ($source in @($client, $server)) {
        if (-not (Test-Path -LiteralPath $source)) { throw "Missing SDK artifact: $source" }
    }
    $clientTarget = Join-Path $Paths.runtime "$($script:Project.gameToken)\cl_dlls"
    $serverTarget = Join-Path $Paths.runtime "$($script:Project.gameToken)\dlls"
    New-Item -ItemType Directory -Force -Path $clientTarget, $serverTarget | Out-Null
    Copy-Item -LiteralPath $client -Destination (Join-Path $clientTarget 'client_amd64.dll') -Force
    Copy-Item -LiteralPath $server -Destination (Join-Path $serverTarget 'einar_amd64.dll') -Force

    $runtimeState = Test-Runtime $Paths.runtime
    if (-not $runtimeState.valid) {
        throw "Assembled runtime is incomplete: $($runtimeState.missing -join ', ')"
    }
    return [ordered]@{
        api = $api
        logs = $logs
        runtime = $runtimeState
    }
}

function Test-Runtime {
    param([Parameter(Mandatory)][string]$Runtime)
    $required = @()
    foreach ($artifact in $script:Project.requiredArtifacts.engine) {
        $required += "rt_bin/$artifact"
    }
    foreach ($artifact in $script:Project.requiredArtifacts.sdk) {
        $required += [string]$artifact
    }
    $required += @('rt/data/scenes.json', 'rt/data/textures.json', 'StillHunger/gameinfo.txt', 'valve/gameinfo.txt')
    $missing = @(
        foreach ($relative in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $Runtime ($relative -replace '/', '\')) -PathType Leaf)) {
                $relative
            }
        }
    )
    return [ordered]@{
        path = $Runtime
        valid = $missing.Count -eq 0
        missing = $missing
    }
}

function Get-ExactRuntimeProcesses {
    param([Parameter(Mandatory)][string]$Executable)
    $target = [IO.Path]::GetFullPath($Executable)
    return @(
        Get-CimInstance Win32_Process -Filter "Name = 'xash3d.exe'" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ExecutablePath -and
                [IO.Path]::GetFullPath($_.ExecutablePath).Equals($target, [StringComparison]::OrdinalIgnoreCase)
            }
    )
}

function Assert-RuntimeIdle {
    param([Parameter(Mandatory)][string]$Runtime)
    $executable = Join-Path $Runtime 'rt_bin\xash3d.exe'
    $processes = Get-ExactRuntimeProcesses $executable
    if ($processes.Count -gt 0) {
        throw "Runtime is in use by PID(s): $($processes.ProcessId -join ', ')."
    }
}

function Save-Screenshot {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$Path
    )
    if ($Process.HasExited -or $Process.MainWindowHandle -eq [IntPtr]::Zero) { return $null }
    if (-not ('StillHungerCapture' -as [type])) {
        Add-Type -AssemblyName System.Drawing
        Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class StillHungerCapture {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
}
'@
    }
    $rect = New-Object StillHungerCapture+RECT
    if (-not [StillHungerCapture]::GetWindowRect($Process.MainWindowHandle, [ref]$rect)) { return $null }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) { return $null }
    $bitmap = [Drawing.Bitmap]::new($width, $height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $dc = $graphics.GetHdc()
        try { $null = [StillHungerCapture]::PrintWindow($Process.MainWindowHandle, $dc, 2) }
        finally { $graphics.ReleaseHdc($dc) }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    return $Path
}

function Stop-OwnedProcess {
    param(
        [Parameter(Mandatory)][int]$Pid,
        [Parameter(Mandatory)][DateTime]$StartTime,
        [Parameter(Mandatory)][string]$Executable
    )
    $process = Get-Process -Id $Pid -ErrorAction SilentlyContinue
    if (-not $process) { return 'already-exited' }
    $actualPath = $process.Path
    if (-not $actualPath.Equals([IO.Path]::GetFullPath($Executable), [StringComparison]::OrdinalIgnoreCase) -or
        [Math]::Abs(($process.StartTime - $StartTime).TotalSeconds) -gt 1) {
        throw "Refusing to stop PID $Pid because its identity no longer matches the process this command started."
    }
    $null = $process.CloseMainWindow()
    if (-not $process.WaitForExit(5000)) {
        Stop-Process -Id $Pid
        $process.WaitForExit(5000)
        return 'terminated'
    }
    return 'closed'
}

function Start-Interactive {
    param(
        [Parameter(Mandatory)][string]$Runtime,
        [Parameter(Mandatory)][string]$Kind
    )
    $state = Test-Runtime $Runtime
    if (-not $state.valid) { throw "Runtime is incomplete: $($state.missing -join ', ')" }
    Assert-RuntimeIdle $Runtime
    $exe = Join-Path $Runtime 'rt_bin\xash3d.exe'
    $arguments = @($script:Project.smoke.arguments | ForEach-Object { [string]$_ })
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $Runtime -PassThru
    $record = [ordered]@{
        kind = $Kind
        runtime = $Runtime
        executable = $exe
        pid = $process.Id
        startTime = $process.StartTime.ToString('o')
        map = [string]$script:Project.smoke.map
        arguments = $arguments
    }
    $launches = Assert-ProjectPath (Join-Path $script:ProjectRoot '.state\launches')
    Write-JsonAtomic (Join-Path $launches "$($process.Id).json") $record
    return $record
}

function Invoke-Smoke {
    param(
        [Parameter(Mandatory)][string]$Runtime,
        [Parameter(Mandatory)][string]$StateRoot,
        [Parameter(Mandatory)][string]$Kind
    )
    $state = Test-Runtime $Runtime
    if (-not $state.valid) { throw "Runtime is incomplete: $($state.missing -join ', ')" }
    Assert-RuntimeIdle $Runtime
    $exe = Join-Path $Runtime 'rt_bin\xash3d.exe'
    $arguments = @($script:Project.smoke.arguments | ForEach-Object { [string]$_ })
    $log = Join-Path $Runtime 'engine.log'
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $Runtime -PassThru
    $pidStarted = $process.Id
    $startTime = $process.StartTime
    $seconds = [int]$script:Project.smoke.seconds
    $shot = $null
    try {
        for ($i = 0; $i -lt $seconds; $i++) {
            Start-Sleep -Seconds 1
            $process.Refresh()
            if ($process.HasExited) { break }
        }
        if ($Screenshots -and -not $process.HasExited) {
            $shot = Save-Screenshot $process (Join-Path $StateRoot "screenshots\$Kind-$($startTime.ToString('yyyyMMdd-HHmmss')).png")
        }
        $exitBeforeCleanup = if ($process.HasExited) { $process.ExitCode } else { $null }
        $cleanup = Stop-OwnedProcess $pidStarted $startTime $exe
    }
    catch {
        try { $null = Stop-OwnedProcess $pidStarted $startTime $exe } catch {}
        throw
    }
    $logErrors = @()
    if (Test-Path -LiteralPath $log) {
        $logErrors = @(
            Select-String -LiteralPath $log -Pattern 'Sys_Crash|Assertion failed|Host_Error|FATAL ERROR' |
                ForEach-Object { $_.Line }
        )
    }
    $success = ($exitBeforeCleanup -eq $null -or $exitBeforeCleanup -eq 0) -and $logErrors.Count -eq 0
    $record = [ordered]@{
        kind = $Kind
        success = $success
        runtime = $Runtime
        executable = $exe
        pid = $pidStarted
        startTime = $startTime.ToString('o')
        map = [string]$script:Project.smoke.map
        arguments = $arguments
        observedSeconds = $seconds
        exitBeforeCleanup = $exitBeforeCleanup
        cleanup = $cleanup
        log = if (Test-Path -LiteralPath $log) { $log } else { $null }
        logErrors = $logErrors
        screenshot = $shot
        finishedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonAtomic (Join-Path $StateRoot 'smoke.json') $record
    if (-not $success) { throw "Smoke test failed. See '$StateRoot\smoke.json'." }
    return $record
}

function Invoke-NewFeature {
    Require-FeatureName
    Enter-ProjectLock
    $featureRoot = Get-FeatureRoot $Name
    $featureFile = Join-Path $featureRoot 'feature.json'
    if (Test-Path -LiteralPath $featureFile) {
        $existing = Get-Content -LiteralPath $featureFile -Raw | ConvertFrom-Json
        return [ordered]@{ resumed = $true; feature = $existing }
    }
    if (Test-Path -LiteralPath $featureRoot) {
        throw "Feature directory exists without a valid feature.json: $featureRoot"
    }
    $branch = "$($script:Project.branches.featurePrefix)$Name"
    $created = [Collections.Generic.List[object]]::new()
    New-Item -ItemType Directory -Force -Path $featureRoot | Out-Null
    try {
        foreach ($component in @('engine', 'sdk', 'rtgl1')) {
            $repo = Get-RepoPath $component
            if (-not (Test-GitClean $repo)) { throw "Canonical $component repository is dirty." }
            $path = Join-Path $featureRoot $component
            $null = Invoke-Git $repo @('worktree', 'add', '-b', $branch, $path, [string]$script:Project.branches.$component)
            $created.Add([pscustomobject]@{ repo = $repo; path = $path; branch = $branch })
        }
        $content = Get-RepoPath 'content'
        if (-not (Test-GitClean $content)) { throw 'Canonical content repository is dirty.' }
        $runtime = Join-Path $featureRoot 'runtime'
        $null = Invoke-Git $content @('worktree', 'add', '-b', $branch, $runtime, [string]$script:Project.branches.content)
        $created.Add([pscustomobject]@{ repo = $content; path = $runtime; branch = $branch })
        $feature = [ordered]@{
            schemaVersion = 1
            name = $Name
            branch = $branch
            status = 'active'
            createdUtc = [DateTime]::UtcNow.ToString('o')
            paths = [ordered]@{
                engine = Join-Path $featureRoot 'engine'
                sdk = Join-Path $featureRoot 'sdk'
                rtgl1 = Join-Path $featureRoot 'rtgl1'
                runtime = $runtime
            }
        }
        Write-JsonAtomic $featureFile $feature
        return [ordered]@{ resumed = $false; feature = $feature }
    }
    catch {
        foreach ($entry in @(Get-Reversed $created)) {
            try { $null = Invoke-Git $entry.repo @('worktree', 'remove', '--force', $entry.path) } catch {}
            try { $null = Invoke-Git $entry.repo @('branch', '-D', $entry.branch) } catch {}
        }
        if (Test-Path -LiteralPath $featureRoot) { Remove-Item -LiteralPath $featureRoot -Recurse -Force }
        throw
    }
}

function Invoke-Status {
    Require-FeatureName
    $feature = Get-Feature $Name
    $paths = Get-BuildPaths $feature
    $repositories = [ordered]@{
        engine = Get-GitInfo $paths.engine
        sdk = Get-GitInfo $paths.sdk
        rtgl1 = Get-GitInfo $paths.rtgl1
        content = Get-GitInfo $paths.runtime
        mainui = Get-GitInfo (Get-RepoPath 'mainui')
    }
    $stateRoot = Join-Path (Get-FeatureRoot $Name) '.state'
    $buildFile = Join-Path $stateRoot 'build.json'
    $smokeFile = Join-Path $stateRoot 'smoke.json'
    return [ordered]@{
        feature = $feature
        repositories = $repositories
        api = Get-ApiState $paths.engine $paths.sdk
        runtime = Test-Runtime $paths.runtime
        build = if (Test-Path -LiteralPath $buildFile) { Get-Content $buildFile -Raw | ConvertFrom-Json } else { $null }
        smoke = if (Test-Path -LiteralPath $smokeFile) { Get-Content $smokeFile -Raw | ConvertFrom-Json } else { $null }
    }
}

function Invoke-BuildFeature {
    Require-FeatureName
    Enter-ProjectLock
    $feature = Get-Feature $Name
    $paths = Get-BuildPaths $feature
    $stateRoot = Join-Path (Get-FeatureRoot $Name) '.state'
    $result = Invoke-BuildSet $paths $stateRoot
    $commits = [ordered]@{
        engine = (Invoke-Git $paths.engine @('rev-parse', 'HEAD'))
        sdk = (Invoke-Git $paths.sdk @('rev-parse', 'HEAD'))
        rtgl1 = (Invoke-Git $paths.rtgl1 @('rev-parse', 'HEAD'))
        content = (Invoke-Git $paths.runtime @('rev-parse', 'HEAD'))
        mainui = (Invoke-Git (Get-RepoPath 'mainui') @('rev-parse', 'HEAD'))
    }
    $record = [ordered]@{
        success = $true
        builtUtc = [DateTime]::UtcNow.ToString('o')
        commits = $commits
        api = $result.api
        logs = $result.logs
        runtime = $result.runtime
        artifacts = @(
            foreach ($relative in @(
                'rt_bin\xash3d.exe',
                'rt_bin\xash.dll',
                'rt_bin\filesystem_stdio.dll',
                'rt_bin\ref_gl.dll',
                'rt_bin\menu.dll',
                'rt_bin\RayTracedGL1.dll',
                'rt_bin\SDL2.dll',
                'StillHunger\cl_dlls\client_amd64.dll',
                'StillHunger\dlls\einar_amd64.dll'
            )) {
                $file = Join-Path $paths.runtime $relative
                [ordered]@{
                    path = $relative.Replace('\', '/')
                    length = (Get-Item -LiteralPath $file).Length
                    sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        )
    }
    Write-JsonAtomic (Join-Path $stateRoot 'build.json') $record
    return $record
}

function Get-NextReleaseId {
    $root = Resolve-ProjectPath $script:Project.paths.releases
    $numbers = @(
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object Name -Match '^\d+$' |
            ForEach-Object { [int]$_.Name }
    )
    if ($numbers.Count -eq 0) { return '1' }
    return [string](($numbers | Measure-Object -Maximum).Maximum + 1)
}

function Stage-Preprod {
    param([Parameter(Mandatory)][string]$ReleaseId)
    $releaseRoot = Join-Path (Resolve-ProjectPath $script:Project.paths.releases) $ReleaseId
    $payload = Join-Path $releaseRoot 'payload'
    $manifestFile = Join-Path $releaseRoot 'release.json'
    if (-not (Test-Path -LiteralPath $manifestFile)) { throw "Release '$ReleaseId' does not exist." }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    $preprod = Resolve-ProjectPath $script:Project.paths.preprod
    Assert-RuntimeIdle $preprod
    $parent = Split-Path -Parent $preprod
    $stage = Assert-ProjectPath (Join-Path $parent ".preprod-staging-$ReleaseId")
    $backup = Assert-ProjectPath (Join-Path $parent '.preprod-backup')
    foreach ($path in @($stage, $backup)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    Copy-Tree $payload $stage
    $actual = Get-HashInventory $stage
    $expectedJson = @($manifest.files) | ConvertTo-Json -Depth 5 -Compress
    $actualJson = @($actual) | ConvertTo-Json -Depth 5 -Compress
    if ($expectedJson -cne $actualJson) {
        Remove-Item -LiteralPath $stage -Recurse -Force
        throw "Preprod staging hash verification failed for release '$ReleaseId'."
    }
    try {
        if (Test-Path -LiteralPath $preprod) { Move-Item -LiteralPath $preprod -Destination $backup }
        Move-Item -LiteralPath $stage -Destination $preprod
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
    }
    catch {
        if (-not (Test-Path -LiteralPath $preprod) -and (Test-Path -LiteralPath $backup)) {
            Move-Item -LiteralPath $backup -Destination $preprod
        }
        throw
    }
    Write-JsonAtomic (Join-Path $script:ProjectRoot '.state\preprod.json') ([ordered]@{
        release = $ReleaseId
        stagedUtc = [DateTime]::UtcNow.ToString('o')
        manifest = $manifestFile
    })
    return [ordered]@{ release = $ReleaseId; path = $preprod; files = $actual.Count }
}

function New-CleanRelease {
    param([Parameter(Mandatory)][string]$ReleaseId)
    $workRoot = Resolve-ProjectPath $script:Project.paths.work
    $sourceRoot = Assert-ProjectPath (Join-Path $workRoot ".release-$ReleaseId")
    $releaseRoot = Join-Path (Resolve-ProjectPath $script:Project.paths.releases) $ReleaseId
    $staging = Assert-ProjectPath (Join-Path (Resolve-ProjectPath $script:Project.paths.releases) ".staging-$ReleaseId")
    if (Test-Path -LiteralPath $releaseRoot) { throw "Release '$ReleaseId' already exists." }
    if (Test-Path -LiteralPath $sourceRoot) { Remove-Item -LiteralPath $sourceRoot -Recurse -Force }
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
    $added = [Collections.Generic.List[object]]::new()
    try {
        $paths = [ordered]@{}
        foreach ($component in @('engine', 'sdk', 'rtgl1', 'content')) {
            $repo = Get-RepoPath $component
            $pathName = if ($component -eq 'content') { 'runtime' } else { $component }
            $path = Join-Path $sourceRoot $pathName
            $branch = [string]$script:Project.branches.$component
            $null = Invoke-Git $repo @('worktree', 'add', '--detach', $path, $branch)
            $added.Add([pscustomobject]@{ repo = $repo; path = $path })
            $paths[$pathName] = $path
        }
        $stateRoot = Join-Path $sourceRoot '.state'
        $buildPaths = [ordered]@{
            engine = $paths.engine
            sdk = $paths.sdk
            rtgl1 = $paths.rtgl1
            runtime = $paths.runtime
        }
        $build = Invoke-BuildSet $buildPaths $stateRoot
        New-Item -ItemType Directory -Force -Path (Join-Path $staging 'payload') | Out-Null
        Copy-DeployableTree $paths.runtime (Join-Path $staging 'payload')
        $runtime = Test-Runtime (Join-Path $staging 'payload')
        if (-not $runtime.valid) { throw "Release payload is incomplete: $($runtime.missing -join ', ')" }
        $commits = [ordered]@{
            orchestration = (Invoke-Git $script:ProjectRoot @('rev-parse', 'HEAD'))
            engine = (Invoke-Git $paths.engine @('rev-parse', 'HEAD'))
            sdk = (Invoke-Git $paths.sdk @('rev-parse', 'HEAD'))
            rtgl1 = (Invoke-Git $paths.rtgl1 @('rev-parse', 'HEAD'))
            mainui = (Invoke-Git (Get-RepoPath 'mainui') @('rev-parse', [string]$script:Project.branches.mainui))
            content = (Invoke-Git $paths.runtime @('rev-parse', 'HEAD'))
        }
        $manifest = [ordered]@{
            schemaVersion = 1
            release = $ReleaseId
            createdUtc = [DateTime]::UtcNow.ToString('o')
            commits = $commits
            api = $build.api
            files = Get-HashInventory (Join-Path $staging 'payload')
        }
        Write-JsonAtomic (Join-Path $staging 'release.json') $manifest
        Move-Item -LiteralPath $staging -Destination $releaseRoot
        $manifestCopy = Join-Path (Resolve-ProjectPath $script:Project.paths.releaseManifests) "$ReleaseId.json"
        Write-JsonAtomic $manifestCopy $manifest
        $preprod = Stage-Preprod $ReleaseId
        return [ordered]@{
            release = $ReleaseId
            path = $releaseRoot
            manifest = Join-Path $releaseRoot 'release.json'
            preprod = $preprod
        }
    }
    catch {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        throw
    }
    finally {
        foreach ($entry in @(Get-Reversed $added)) {
            try { $null = Invoke-Git $entry.repo @('worktree', 'remove', '--force', $entry.path) } catch {}
        }
        if (Test-Path -LiteralPath $sourceRoot) { Remove-Item -LiteralPath $sourceRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-Finish {
    Require-FeatureName
    Enter-ProjectLock
    $feature = Get-Feature $Name
    $paths = Get-BuildPaths $feature
    $stateRoot = Join-Path (Get-FeatureRoot $Name) '.state'
    $buildFile = Join-Path $stateRoot 'build.json'
    $smokeFile = Join-Path $stateRoot 'smoke.json'
    if (-not (Test-Path -LiteralPath $buildFile)) { throw 'A current successful build is required before finish.' }
    if (-not (Test-Path -LiteralPath $smokeFile)) { throw 'A current successful feature smoke test is required before finish.' }
    $smoke = Get-Content -LiteralPath $smokeFile -Raw | ConvertFrom-Json
    if (-not $smoke.success) { throw 'The latest feature smoke test did not succeed.' }
    foreach ($path in @($paths.engine, $paths.sdk, $paths.rtgl1, $paths.runtime)) {
        if (-not (Test-GitClean $path)) { throw "Feature worktree is dirty: $path" }
    }
    $build = Get-Content -LiteralPath $buildFile -Raw | ConvertFrom-Json
    foreach ($component in @('engine', 'sdk', 'rtgl1')) {
        $actual = Invoke-Git $paths.$component @('rev-parse', 'HEAD')
        if ($actual -ne $build.commits.$component) { throw "$component changed after the last build." }
    }
    $contentActual = Invoke-Git $paths.runtime @('rev-parse', 'HEAD')
    if ($contentActual -ne $build.commits.content) { throw 'Content changed after the last build.' }

    $branch = [string]$feature.branch
    $preMerge = [ordered]@{}
    $merged = [Collections.Generic.List[string]]::new()
    try {
        foreach ($component in @('engine', 'sdk', 'rtgl1', 'content')) {
            $repo = Get-RepoPath $component
            if (-not (Test-GitClean $repo)) { throw "Canonical $component repository is dirty." }
            $master = [string]$script:Project.branches.$component
            $null = Invoke-Git $repo @('switch', $master)
            $preMerge[$component] = Invoke-Git $repo @('rev-parse', 'HEAD')
            $ahead = [int](Invoke-Git $repo @('rev-list', '--count', "$master..$branch"))
            if ($ahead -gt 0) {
                $null = Invoke-Git $repo @('merge', '--no-ff', '-m', "Merge $branch", $branch)
                $merged.Add($component)
            }
        }
        Assert-ApiCompatible (Get-RepoPath 'engine') (Get-RepoPath 'sdk') | Out-Null
        $releaseId = Get-NextReleaseId
        $releaseResult = New-CleanRelease $releaseId
    }
    catch {
        foreach ($component in @(Get-Reversed $merged)) {
            $repo = Get-RepoPath $component
            try { $null = Invoke-Git $repo @('reset', '--hard', [string]$preMerge[$component]) } catch {}
        }
        throw
    }
    foreach ($component in @('engine', 'sdk', 'rtgl1')) {
        $repo = Get-RepoPath $component
        $null = Invoke-Git $repo @('worktree', 'remove', '--force', [string]$paths.$component)
        $null = Invoke-Git $repo @('branch', '-d', $branch)
    }
    $contentRepo = Get-RepoPath 'content'
    $null = Invoke-Git $contentRepo @('worktree', 'remove', '--force', [string]$paths.runtime)
    $null = Invoke-Git $contentRepo @('branch', '-d', $branch)
    $feature.status = 'finished'
    $feature.finishedUtc = [DateTime]::UtcNow.ToString('o')
    $feature.release = $releaseResult.release
    $archiveRecord = Assert-ProjectPath (Join-Path $script:ProjectRoot ".state\finished\$Name.json")
    Write-JsonAtomic $archiveRecord $feature
    $featureRoot = Get-FeatureRoot $Name
    if (Test-Path -LiteralPath $featureRoot) { Remove-Item -LiteralPath $featureRoot -Recurse -Force }
    return [ordered]@{
        merged = @($merged)
        release = $releaseResult
        archivedFeature = $archiveRecord
    }
}

function Assert-ReleaseHashes {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Root,
        [switch]$IgnoreUserOwned
    )
    $errors = [Collections.Generic.List[string]]::new()
    foreach ($entry in $Manifest.files) {
        $relative = [string]$entry.path
        if ($IgnoreUserOwned -and (Test-UserOwned $relative)) { continue }
        $file = Join-Path $Root ($relative -replace '/', '\')
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            $errors.Add("missing:$relative")
            continue
        }
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -cne [string]$entry.sha256) { $errors.Add("hash:$relative") }
    }
    if ($errors.Count -gt 0) { throw "Release hash verification failed: $($errors -join ', ')" }
}

function Invoke-Promote {
    if ([string]::IsNullOrWhiteSpace($Release)) { throw "-Release is required for 'promote'." }
    Enter-ProjectLock
    $releaseRoot = Join-Path (Resolve-ProjectPath $script:Project.paths.releases) $Release
    $manifestFile = Join-Path $releaseRoot 'release.json'
    $payload = Join-Path $releaseRoot 'payload'
    if (-not (Test-Path -LiteralPath $manifestFile)) { throw "Release '$Release' does not exist." }
    $preprodStateFile = Join-Path $script:ProjectRoot '.state\preprod.json'
    $preprodSmokeFile = Join-Path $script:ProjectRoot '.state\preprod-smoke\smoke.json'
    if (-not (Test-Path -LiteralPath $preprodStateFile) -or -not (Test-Path -LiteralPath $preprodSmokeFile)) {
        throw 'The exact release must be staged and successfully smoke-tested in preprod before promotion.'
    }
    $preprodState = Get-Content -LiteralPath $preprodStateFile -Raw | ConvertFrom-Json
    $preprodSmoke = Get-Content -LiteralPath $preprodSmokeFile -Raw | ConvertFrom-Json
    if ([string]$preprodState.release -ne $Release -or -not $preprodSmoke.success) {
        throw 'Preprod state/smoke result does not match the requested release.'
    }
    $production = [IO.Path]::GetFullPath([string]$script:Project.paths.production)
    Assert-RuntimeIdle $production
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    $parent = Split-Path -Parent $production
    $stage = Join-Path $parent ".$([IO.Path]::GetFileName($production)).staging-$Release"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    Copy-Tree $payload $stage
    Assert-ReleaseHashes $manifest $stage
    if (Test-Path -LiteralPath $production) {
        foreach ($entry in $script:Project.userOwned) {
            $pattern = [string]$entry
            if ($pattern.EndsWith('/**')) {
                $relative = $pattern.Substring(0, $pattern.Length - 3)
                $source = Join-Path $production ($relative -replace '/', '\')
                if (Test-Path -LiteralPath $source -PathType Container) {
                    $target = Join-Path $stage ($relative -replace '/', '\')
                    Copy-Tree $source $target
                }
            }
            else {
                $source = Join-Path $production ($pattern -replace '/', '\')
                if (Test-Path -LiteralPath $source -PathType Leaf) {
                    $target = Join-Path $stage ($pattern -replace '/', '\')
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
                    Copy-Item -LiteralPath $source -Destination $target -Force
                }
            }
        }
    }
    Assert-ReleaseHashes $manifest $stage -IgnoreUserOwned
    $backup = $null
    try {
        if (Test-Path -LiteralPath $production) {
            $backup = "$production.rollback-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
            Move-Item -LiteralPath $production -Destination $backup
        }
        Move-Item -LiteralPath $stage -Destination $production
    }
    catch {
        if (-not (Test-Path -LiteralPath $production) -and $backup -and (Test-Path -LiteralPath $backup)) {
            Move-Item -LiteralPath $backup -Destination $production
        }
        throw
    }
    $record = [ordered]@{
        release = $Release
        production = $production
        previous = $backup
        promotedUtc = [DateTime]::UtcNow.ToString('o')
        manifest = $manifestFile
    }
    Write-JsonAtomic (Join-Path $script:ProjectRoot '.state\production.json') $record
    return $record
}

function Invoke-Rollback {
    Enter-ProjectLock
    $stateFile = Join-Path $script:ProjectRoot '.state\production.json'
    if (-not (Test-Path -LiteralPath $stateFile)) { throw 'No production rollback record exists.' }
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    $production = [IO.Path]::GetFullPath([string]$state.production)
    $previous = [IO.Path]::GetFullPath([string]$state.previous)
    if (-not (Test-Path -LiteralPath $previous -PathType Container)) { throw "Rollback directory is missing: $previous" }
    Assert-RuntimeIdle $production
    $failed = "$production.failed-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
    if (Test-Path -LiteralPath $production) { Move-Item -LiteralPath $production -Destination $failed }
    try {
        Move-Item -LiteralPath $previous -Destination $production
    }
    catch {
        if (-not (Test-Path -LiteralPath $production) -and (Test-Path -LiteralPath $failed)) {
            Move-Item -LiteralPath $failed -Destination $production
        }
        throw
    }
    $record = [ordered]@{
        production = $production
        restoredFrom = $previous
        displaced = $failed
        rolledBackUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonAtomic (Join-Path $script:ProjectRoot '.state\rollback.json') $record
    return $record
}

try {
    $result = switch ($Command) {
        'new' { Invoke-NewFeature }
        'status' { Invoke-Status }
        'build' { Invoke-BuildFeature }
        'launch-feature' {
            Require-FeatureName
            $feature = Get-Feature $Name
            Start-Interactive ([string]$feature.paths.runtime) "feature:$Name"
        }
        'smoke-feature' {
            Require-FeatureName
            Enter-ProjectLock
            $feature = Get-Feature $Name
            Invoke-Smoke ([string]$feature.paths.runtime) (Join-Path (Get-FeatureRoot $Name) '.state') "feature-$Name"
        }
        'finish' { Invoke-Finish }
        'launch-preprod' {
            Start-Interactive (Resolve-ProjectPath $script:Project.paths.preprod) 'preprod'
        }
        'smoke-preprod' {
            Enter-ProjectLock
            Invoke-Smoke (Resolve-ProjectPath $script:Project.paths.preprod) (Join-Path $script:ProjectRoot '.state\preprod-smoke') 'preprod'
        }
        'promote' { Invoke-Promote }
        'smoke-production' {
            Enter-ProjectLock
            Invoke-Smoke ([IO.Path]::GetFullPath([string]$script:Project.paths.production)) (Join-Path $script:ProjectRoot '.state\production-smoke') 'production'
        }
        'rollback' { Invoke-Rollback }
    }
    [ordered]@{
        success = $true
        command = $Command
        result = $result
    } | ConvertTo-Json -Depth 30
    exit 0
}
catch {
    [ordered]@{
        success = $false
        command = $Command
        error = $_.Exception.Message
        type = $_.Exception.GetType().FullName
    } | ConvertTo-Json -Depth 10
    exit 1
}
finally {
    Exit-ProjectLock
}
