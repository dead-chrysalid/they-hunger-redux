[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet(
        'new',
        'sources',
        'build-code',
        'assemble',
        'smoke-assembled',
        'status',
        'sync',
        'build',
        'audit',
        'launch-feature',
        'smoke-feature',
        'smoke-campaign',
        'finish',
        'hotfix-defaults',
        'test-hotfix',
        'launch-preprod',
        'smoke-preprod',
        'promote',
        'smoke-production',
        'rollback'
    )]
    [string]$Command,

    [string]$Name,
    [string]$Release,
    [string]$SettingsFile,
    [string]$Resources,
    [string]$Output,
    [switch]$Screenshots
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Initialize-GitToolchainPath {
    # Sandboxed/embedded shells can expose git.exe while omitting the Unix
    # helpers used by Git for Windows scripts such as git-submodule. Resolve
    # the installation that owns git.exe and repair PATH only for this wrapper
    # process; never depend on a user or machine PATH edit.
    $gitCommand = Get-Command git.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $directory = Split-Path -Parent $gitCommand.Source
    $gitRoot = $null

    for ($depth = 0; $depth -lt 5 -and $directory; $depth++) {
        $basename = Join-Path $directory 'usr\bin\basename.exe'
        $gitShellSetup = Join-Path $directory 'mingw64\libexec\git-core\git-sh-setup'
        if ((Test-Path -LiteralPath $basename -PathType Leaf) -and
            (Test-Path -LiteralPath $gitShellSetup -PathType Leaf)) {
            $gitRoot = $directory
            break
        }

        $parent = Split-Path -Parent $directory
        if ($parent -eq $directory) { break }
        $directory = $parent
    }

    if (-not $gitRoot) {
        throw "Could not resolve the complete Git for Windows toolchain from '$($gitCommand.Source)'."
    }

    $requiredPaths = @(
        (Join-Path $gitRoot 'cmd'),
        (Join-Path $gitRoot 'bin'),
        (Join-Path $gitRoot 'usr\bin'),
        (Join-Path $gitRoot 'mingw64\bin'),
        (Join-Path $gitRoot 'mingw64\libexec\git-core')
    )
    $existingPaths = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $env:Path = (@($requiredPaths + $existingPaths) | Select-Object -Unique) -join ';'
    $script:GitBash = Join-Path $gitRoot 'bin\bash.exe'
}

Initialize-GitToolchainPath

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::OpenRead([IO.Path]::GetFullPath($Path))
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha256.ComputeHash($stream)
        return ([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant())
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

$script:ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:ProjectFile = Join-Path $script:ProjectRoot 'project.json'
$script:Project = Get-Content -LiteralPath $script:ProjectFile -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'StillHunger.ContentAudit.ps1')
. (Join-Path $PSScriptRoot 'StillHunger.Hotfix.ps1')
. (Join-Path $PSScriptRoot 'StillHunger.Publication.ps1')
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
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
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

function Get-BranchDivergence {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$BaseBranch
    )
    $head = Invoke-Git $Repository @('rev-parse', 'HEAD')
    $base = Invoke-Git $Repository @('rev-parse', $BaseBranch)
    $ahead = [int](Invoke-Git $Repository @('rev-list', '--count', "$BaseBranch..HEAD"))
    $behind = [int](Invoke-Git $Repository @('rev-list', '--count', "HEAD..$BaseBranch"))
    return [ordered]@{
        baseBranch = $BaseBranch
        baseCommit = $base
        headCommit = $head
        ahead = $ahead
        behind = $behind
        current = ($behind -eq 0)
        diverged = ($ahead -gt 0 -and $behind -gt 0)
    }
}

function Get-FeatureGitInfo {
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Component
    )
    $info = Get-GitInfo $Repository
    $divergence = Get-BranchDivergence $Repository ([string]$script:Project.branches.$Component)
    $info['integration'] = $divergence
    return $info
}

function Get-FeatureComponentPaths {
    param([Parameter(Mandatory)]$Feature)
    $paths = Get-BuildPaths $Feature
    return [ordered]@{
        engine = $paths.engine
        sdk = $paths.sdk
        rtgl1 = $paths.rtgl1
        content = $paths.runtime
    }
}

function Remove-FeatureVerification {
    param([Parameter(Mandatory)][string]$StateRoot)
    $removed = [Collections.Generic.List[string]]::new()
    foreach ($name in @('build.json', 'smoke.json', 'campaign-smoke.json', 'audit.json')) {
        $path = Join-Path $StateRoot $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
            $removed.Add($name)
        }
    }
    return @($removed)
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
                    sha256 = Get-FileSha256 $_.FullName
                }
            }
    )
}

function Assert-DependencyInventory {
    param([Parameter(Mandatory)][string]$Name)

    $dependency = $script:Project.dependencies.$Name
    if (-not $dependency) {
        throw "Unknown dependency: $Name"
    }
    $root = Resolve-ProjectPath ([string]$dependency.path)
    $manifest = Resolve-ProjectPath ([string]$dependency.manifest)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Dependency '$Name' is missing at '$root'."
    }
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "Dependency manifest for '$Name' is missing: $manifest"
    }

    $expected = @(
        Import-Csv -LiteralPath $manifest |
            ForEach-Object {
                [pscustomobject]@{
                    path = [string]$_.Path
                    length = [long]$_.Length
                    sha256 = ([string]$_.SHA256).ToLowerInvariant()
                }
            }
    )
    $actual = @(Get-HashInventory $root)
    if ($actual.Count -ne $expected.Count) {
        throw "Dependency '$Name' inventory count mismatch: expected $($expected.Count), found $($actual.Count)."
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        $wanted = $expected[$index]
        $found = $actual[$index]
        if ($wanted.path -cne $found.path -or
            $wanted.length -ne $found.length -or
            $wanted.sha256 -cne $found.sha256) {
            throw "Dependency '$Name' inventory mismatch at '$($wanted.path)'."
        }
    }

    return [ordered]@{
        name = $Name
        root = $root
        manifest = $manifest
        version = [string]$dependency.version
        files = $actual.Count
    }
}

function Test-Excluded {
    param([Parameter(Mandatory)][string]$RelativePath)
    $relative = $RelativePath.Replace('\', '/')
    foreach ($pattern in $script:Project.releaseExclusions) {
        if ([System.Management.Automation.WildcardPattern]::new(
                [string]$pattern,
                [System.Management.Automation.WildcardOptions]::IgnoreCase
            ).IsMatch($relative)) {
            return $true
        }
    }
    return $false
}

function Test-UserOwned {
    param([Parameter(Mandatory)][string]$RelativePath)
    $relative = $RelativePath.Replace('\', '/')
    foreach ($pattern in $script:Project.userOwned) {
        if ([System.Management.Automation.WildcardPattern]::new(
                [string]$pattern,
                [System.Management.Automation.WildcardOptions]::IgnoreCase
            ).IsMatch($relative)) {
            return $true
        }
    }
    return $false
}

function Test-ResetOnPromote {
    param([Parameter(Mandatory)][string]$RelativePath)
    $relative = $RelativePath.Replace('\', '/')
    foreach ($pattern in $script:Project.releasePolicy.resetOnPromotePaths) {
        if ([System.Management.Automation.WildcardPattern]::new(
                [string]$pattern,
                [System.Management.Automation.WildcardOptions]::IgnoreCase
            ).IsMatch($relative)) {
            return $true
        }
    }
    return $false
}

function Invoke-LoggedGitScript {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Log
    )
    # Codex may restore its parent PATH when a native child starts, defeating a
    # PowerShell-only PATH repair. A Git Bash login shell reconstructs /usr/bin
    # and Git's exec path before shell-backed commands such as submodule run.
    $singleQuote = [string][char]39
    $doubleQuote = [string][char]34
    $embeddedQuote = $singleQuote + $doubleQuote + $singleQuote + $doubleQuote + $singleQuote
    $quotedArguments = @($Arguments | ForEach-Object {
        $singleQuote + $_.Replace($singleQuote, $embeddedQuote) + $singleQuote
    })
    $commandLine = 'exec git ' + ($quotedArguments -join ' ')
    $bashArguments = @('-lc', $commandLine)
    Invoke-Logged -Executable $script:GitBash -Arguments $bashArguments -Log $Log
}

function Convert-StateTimestampToUtc {
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [DateTimeOffset]) {
        return ([DateTimeOffset]$Value).UtcDateTime
    }
    if ($Value -is [DateTime]) {
        return ([DateTime]$Value).ToUniversalTime()
    }
    return [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).UtcDateTime
}

function Test-FeatureProfile {
    param([Parameter(Mandatory)][string]$RelativePath)
    $relative = $RelativePath.Replace('\', '/')
    foreach ($pattern in $script:Project.featureProfile) {
        if ([System.Management.Automation.WildcardPattern]::new(
                [string]$pattern,
                [System.Management.Automation.WildcardOptions]::IgnoreCase
            ).IsMatch($relative)) {
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

function Move-DirectoryAtomic {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $sourcePath = [IO.Path]::GetFullPath($Source)
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Directory move source does not exist: $sourcePath"
    }
    if (Test-Path -LiteralPath $destinationPath) {
        throw "Directory move destination already exists: $destinationPath"
    }
    if ([IO.Path]::GetPathRoot($sourcePath) -cne [IO.Path]::GetPathRoot($destinationPath)) {
        throw "Atomic directory moves must stay on one volume: $sourcePath -> $destinationPath"
    }

    [IO.Directory]::Move($sourcePath, $destinationPath)
}

function Copy-ValveRuntime {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    $sourceRoot = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $spriteFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($sprite in $script:Project.releasePolicy.valveSpriteFiles) {
        $null = $spriteFiles.Add(([string]$sprite).Replace('\', '/'))
    }

    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File) {
        $relative = $file.FullName.Substring($sourceRoot.Length + 1).Replace('\', '/')
        $include = $spriteFiles.Contains($relative)
        if (-not $include) {
            foreach ($pattern in $script:Project.releasePolicy.valveIncludePatterns) {
                if ([System.Management.Automation.WildcardPattern]::new(
                        [string]$pattern,
                        [System.Management.Automation.WildcardOptions]::IgnoreCase
                    ).IsMatch($relative)) {
                    $include = $true
                    break
                }
            }
        }
        if (-not $include) { continue }

        $target = Join-Path $Destination ($relative -replace '/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}

function Copy-RuntimeBase {
    param([Parameter(Mandatory)][string]$Runtime)

    $runtimeBase = Resolve-ProjectPath $script:Project.paths.runtimeBase
    if (Test-Path -LiteralPath $runtimeBase -PathType Container) {
        Copy-Tree $runtimeBase $Runtime
    }
}

function Copy-ProductionProfileDefaults {
    param([Parameter(Mandatory)][string]$Runtime)

    $production = [IO.Path]::GetFullPath([string]$script:Project.paths.production)
    $copied = [Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $production -PathType Container)) {
        return @($copied)
    }

    foreach ($entry in $script:Project.featureProfile) {
        $relative = ([string]$entry).Replace('/', '\')
        $source = Join-Path $production $relative
        $target = Join-Path $Runtime $relative
        if ((Test-Path -LiteralPath $source -PathType Leaf) -and
            -not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $source -Destination $target
            $copied.Add(([string]$entry).Replace('\', '/'))
        }
    }
    return @($copied)
}

function Copy-FeatureProfileToRelease {
    param(
        [Parameter(Mandatory)][string]$FeatureRuntime,
        [Parameter(Mandatory)][string]$Payload
    )

    $copied = [Collections.Generic.List[string]]::new()
    foreach ($entry in $script:Project.featureProfile) {
        $relative = ([string]$entry).Replace('/', '\')
        $source = Join-Path $FeatureRuntime $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Feature profile file is missing: $source"
        }
        $target = Join-Path $Payload $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
        $copied.Add(([string]$entry).Replace('\', '/'))
    }

    $config = Join-Path $Payload "$($script:Project.gameToken)\config.cfg"
    $null = Set-CleanConfigFile $config
    return @($copied)
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
    # A release checkout must resolve the local menu commit before Git tries
    # the upstream URL from .gitmodules. -c alone is not passed to every
    # nested clone/fetch performed by submodule update.
    $mainuiUrl = $mainui.Replace('\', '/')
    $null = Invoke-Git $Engine @('config', 'submodule.mainui.url', $mainuiUrl)
    Invoke-LoggedGitScript -Arguments @(
        '-C', $Engine,
        '-c', 'protocol.file.allow=always',
        'submodule', 'update', '--init', '--recursive'
    ) -Log (Join-Path $LogRoot 'engine-submodules.log')
    Invoke-LoggedGitScript -Arguments @(
        '-C', $Rtgl1,
        'submodule', 'update', '--init', '--recursive'
    ) -Log (Join-Path $LogRoot 'rtgl1-submodules.log')
}

function Test-MapHasNavigationNodes {
    param([Parameter(Mandatory)][string]$Bsp)
    $bytes = [IO.File]::ReadAllBytes($Bsp)
    if ($bytes.Length -lt 124 -or [BitConverter]::ToInt32($bytes, 0) -ne 30) {
        throw "Invalid GoldSrc BSP header: $Bsp"
    }
    $offset = [BitConverter]::ToInt32($bytes, 4)
    $length = [BitConverter]::ToInt32($bytes, 8)
    if ($offset -lt 0 -or $length -lt 0 -or $offset -gt $bytes.Length -or
        $length -gt ($bytes.Length - $offset)) {
        throw "Invalid entity lump in BSP: $Bsp"
    }
    $entities = [Text.Encoding]::ASCII.GetString($bytes, $offset, $length)
    return $entities -match '"classname"\s+"info_node(?:_air)?"'
}

function Test-CurrentNodeGraph {
    param(
        [Parameter(Mandatory)][string]$Bsp,
        [Parameter(Mandatory)][string]$Graph
    )
    if (-not (Test-Path -LiteralPath $Graph -PathType Leaf)) { return $false }
    $graphFile = Get-Item -LiteralPath $Graph
    if ($graphFile.Length -lt 4 -or $graphFile.LastWriteTimeUtc -lt (Get-Item -LiteralPath $Bsp).LastWriteTimeUtc) {
        return $false
    }
    # An exclusive read also proves the game has closed the graph after writing it.
    try { $stream = [IO.File]::Open($Graph, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None) }
    catch [IO.IOException] { return $false }
    try {
        $header = [byte[]]::new(4)
        if ($stream.Read($header, 0, 4) -ne 4) { return $false }
        return [BitConverter]::ToInt32($header, 0) -eq [int]$script:Project.releasePolicy.nodeGraphVersion
    }
    finally { $stream.Dispose() }
}

function Update-ReleaseNodeGraphs {
    param(
        [Parameter(Mandatory)][string]$Runtime,
        [Parameter(Mandatory)][string]$StateRoot
    )
    $mapsRoot = Join-Path $Runtime "$($script:Project.gameToken)\maps"
    $graphsRoot = Join-Path $mapsRoot 'graphs'
    $rebuilt = [Collections.Generic.List[string]]::new()
    $checked = [Collections.Generic.List[string]]::new()
    foreach ($mapName in $script:Project.releasePolicy.campaignMaps) {
        $name = [string]$mapName
        $bsp = Join-Path $mapsRoot "$name.bsp"
        if (-not (Test-Path -LiteralPath $bsp -PathType Leaf)) {
            throw "Campaign BSP is missing while preparing node graphs: $bsp"
        }
        if (-not (Test-MapHasNavigationNodes $bsp)) { continue }
        $checked.Add($name)
        $graph = Join-Path $graphsRoot "$name.nod"
        # Checkout timestamps cannot prove a graph matches its BSP. Rebuild every node-bearing map.
        # Work only in the detached release runtime; authored content is untouched.
        if (Test-Path -LiteralPath $graph -PathType Leaf) {
            Remove-Item -LiteralPath $graph -Force
        }
        $null = Invoke-Smoke $Runtime (Join-Path $StateRoot 'node-graphs') 'release-node-graph' -Map $name `
            -Seconds ([int]$script:Project.releasePolicy.nodeGraphBuildTimeoutSeconds) `
            -RecordName "maps\$name.json" -SkipAudit -NoScreenshot -ReadyGraphBsp $bsp -ReadyGraphPath $graph
        if (-not (Test-CurrentNodeGraph $bsp $graph)) {
            throw "Node graph for '$name' was not regenerated to match its BSP and graph version."
        }
        $rebuilt.Add($name)
    }
    return [ordered]@{ checked = @($checked); rebuilt = @($rebuilt) }
}

function Copy-InitialDefaults {
    param([Parameter(Mandatory)][string]$Runtime)
    $rootDefaults = Join-Path $Runtime '.workspace\defaults\root'
    $gameDefaults = Join-Path $Runtime (".workspace\defaults\$($script:Project.gameToken)")
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

function Enable-FeatureDevelopmentProfile {
    param([Parameter(Mandatory)][string]$Runtime)

    $rendererFile = Join-Path $Runtime 'RayTracedGL1.json'
    if (-not (Test-Path -LiteralPath $rendererFile -PathType Leaf)) {
        throw "Feature renderer settings are missing: $rendererFile"
    }
    $renderer = Get-Content -LiteralPath $rendererFile -Raw | ConvertFrom-Json
    foreach ($setting in @('developerMode', 'developerWindow')) {
        $value = [bool]$script:Project.development.renderer.$setting
        if ($renderer.PSObject.Properties[$setting]) {
            $renderer.$setting = $value
        }
        else {
            $renderer | Add-Member -NotePropertyName $setting -NotePropertyValue $value
        }
    }
    [IO.File]::WriteAllText(
        $rendererFile,
        ($renderer | ConvertTo-Json -Depth 20) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )

    $userConfig = Join-Path $Runtime "$($script:Project.gameToken)\userconfig.cfg"
    if (-not (Test-Path -LiteralPath $userConfig -PathType Leaf)) {
        throw "Feature user configuration is missing: $userConfig"
    }
    $begin = '// BEGIN feature development profile'
    $end = '// END feature development profile'
    $text = Get-Content -LiteralPath $userConfig -Raw
    $blockPattern = '(?ms)\r?\n?' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end) + '\r?\n?'
    $text = [regex]::Replace($text, $blockPattern, '')
    $commands = @($script:Project.development.gameCommands | ForEach-Object { [string]$_ })
    $block = @($begin) + $commands + @($end)
    $text = $text.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine +
        ($block -join [Environment]::NewLine) + [Environment]::NewLine
    [IO.File]::WriteAllText($userConfig, $text, [Text.UTF8Encoding]::new($false))

    return [ordered]@{
        renderer = $rendererFile
        userConfig = $userConfig
        launchArguments = @($script:Project.development.launchArguments)
        gameCommands = $commands
    }
}

function Get-LaunchArguments {
    param([Parameter(Mandatory)][string]$Kind)

    $arguments = @($script:Project.smoke.arguments | ForEach-Object { [string]$_ })
    if ($Kind.StartsWith('feature', [StringComparison]::OrdinalIgnoreCase)) {
        $developmentArguments = @($script:Project.development.launchArguments | ForEach-Object { [string]$_ })
        $arguments = @($developmentArguments) + $arguments
    }
    return $arguments
}

function Invoke-TextureConversion {
    param(
        [Parameter(Mandatory)][string]$Runtime,
        [Parameter(Mandatory)][string]$StateRoot
    )

    $scriptFile = Resolve-ProjectPath ([string]$script:Project.textureAuthoring.script)
    $sourceRoot = Join-Path $Runtime ([string]$script:Project.textureAuthoring.source -replace '/', '\')
    $outputRoot = Join-Path $Runtime ([string]$script:Project.textureAuthoring.output -replace '/', '\')
    $cacheFile = Join-Path $Runtime ([string]$script:Project.textureAuthoring.cache -replace '/', '\')
    if (-not (Test-Path -LiteralPath $scriptFile -PathType Leaf)) {
        throw "Texture conversion script is missing: $scriptFile"
    }
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "Texture authoring source is missing: $sourceRoot"
    }

    $inputs = @(
        Get-ChildItem -LiteralPath $sourceRoot -Recurse -File |
            Where-Object { $_.Extension.ToLowerInvariant() -in @('.tga', '.png', '.jpg', '.jpeg') }
    )
    if ($inputs.Count -eq 0) {
        return [ordered]@{ success = $true; inputs = 0; outputs = 0; skipped = $true }
    }

    $setup = [string]$script:Project.textureAuthoring.setup
    $python = Resolve-ProjectPath ([string]$script:Project.textureAuthoring.python)
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw "Texture-tools Python is missing at '$python'. Run '$setup' first."
    }
    $dependencyName = [string]$script:Project.textureAuthoring.dependency
    try {
        $dependency = Assert-DependencyInventory $dependencyName
    }
    catch {
        throw "$($_.Exception.Message) Run '$setup' to provision the pinned texture toolchain."
    }
    $compressor = Join-Path ([string]$dependency.root) 'compressonatorcli.exe'
    if (-not (Test-Path -LiteralPath $compressor -PathType Leaf)) {
        throw "Compressonator executable is missing: $compressor"
    }

    $log = Join-Path $StateRoot 'logs\texture-conversion.log'
    Invoke-Logged $python @(
        $scriptFile,
        '--input', $sourceRoot,
        '--output', $outputRoot,
        '--cache', $cacheFile,
        '--compressor', $compressor,
        '--force'
    ) $log

    $missing = [Collections.Generic.List[string]]::new()
    foreach ($input in $inputs) {
        $relative = $input.FullName.Substring($sourceRoot.Length + 1)
        $expected = Join-Path $outputRoot ([IO.Path]::ChangeExtension($relative, '.ktx2'))
        if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) {
            $missing.Add($relative.Replace('\', '/'))
        }
    }
    if ($missing.Count -gt 0) {
        throw "Texture conversion did not produce KTX2 output for: $($missing -join ', ')"
    }

    return [ordered]@{
        success = $true
        inputs = $inputs.Count
        outputs = $inputs.Count
        skipped = $false
        script = $scriptFile
        python = $python
        dependency = $dependency
        compressor = $compressor
        log = $log
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
        [Parameter(Mandatory)][string]$StateRoot,
        [switch]$Development
    )
    $configuration = [string]$script:Project.build.configuration
    $platform = [string]$script:Project.build.platform
    $logs = Join-Path $StateRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logs | Out-Null
    $api = Assert-ApiCompatible $Paths.engine $Paths.sdk
    Initialize-Submodules $Paths.engine $Paths.rtgl1 $logs

    $rtglBuild = Join-Path $Paths.rtgl1 ($script:Project.build.rtgl1Build -replace '/', '\')
    $rtglConfigure = @(
        '-S', $Paths.rtgl1,
        '-B', $rtglBuild,
        '-A', 'x64',
        '-DRG_WITH_SURFACE_WIN32=ON',
        '-DRG_WITH_AMD_FSR2=ON',
        '-DRG_WITH_SHADERS=ON',
        '-DRG_WITH_EDITOR_TESTS=ON',
        '-DRG_WITH_EXAMPLES=OFF',
        '-DCMAKE_POLICY_VERSION_MINIMUM=3.5'
    )
    foreach ($dependency in @('fmt', 'nanorange')) {
        $source = Resolve-ProjectPath ([string]$script:Project.build.rtgl1LocalSources.$dependency)
        if (-not (Test-Path -LiteralPath $source -PathType Container)) {
            throw "The local renderer dependency '$dependency' is missing: $source"
        }
        $rtglConfigure += "-DFETCHCONTENT_SOURCE_DIR_$($dependency.ToUpperInvariant())=$source"
    }
    $rtglConfigure += '-DFETCHCONTENT_UPDATES_DISCONNECTED=ON'
    Invoke-Logged 'cmake' $rtglConfigure (Join-Path $logs 'rtgl1-configure.log')
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
        '-A', 'x64',
        '-D64BIT=ON'
    ) (Join-Path $logs 'sdk-configure.log')
    Invoke-Logged 'cmake' @(
        '--build', $sdkBuild,
        '--config', $configuration,
        '--parallel'
    ) (Join-Path $logs 'sdk-build.log')
    Invoke-Logged 'ctest' @(
        '--test-dir', $sdkBuild,
        '-C', $configuration,
        '--output-on-failure'
    ) (Join-Path $logs 'sdk-tests.log')

    $valve = Resolve-ProjectPath $script:Project.dependencies.valve.path
    Copy-ValveRuntime $valve (Join-Path $Paths.runtime 'valve')
    Copy-RuntimeBase $Paths.runtime
    $inheritedProfile = if ($Development) {
        @(Copy-ProductionProfileDefaults $Paths.runtime)
    }
    else {
        @()
    }
    Copy-InitialDefaults $Paths.runtime
    $developmentProfile = if ($Development) {
        Enable-FeatureDevelopmentProfile $Paths.runtime
    }
    else {
        $null
    }
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
    $rtglShaderOutput = Join-Path $rtglBuild 'shaders'
    $runtimeShaderOutput = Join-Path $Paths.runtime 'rt\shaders'
    $rtglShaderFiles = @(Get-ChildItem -LiteralPath $rtglShaderOutput -Filter '*.spv' -File)
    if ($rtglShaderFiles.Count -eq 0) { throw "Missing renderer shader artifacts: $rtglShaderOutput" }
    New-Item -ItemType Directory -Force -Path $runtimeShaderOutput | Out-Null
    foreach ($shader in $rtglShaderFiles) {
        Copy-Item -LiteralPath $shader.FullName -Destination (Join-Path $runtimeShaderOutput $shader.Name) -Force
    }
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

    # Normal feature profiles disable developer mode, so raw mat_dev images
    # are never loaded. Compile overrides for every runtime we assemble.
    $textureConversion = Invoke-TextureConversion $Paths.runtime $StateRoot

    $runtimeState = Test-Runtime $Paths.runtime
    if (-not $runtimeState.valid) {
        throw "Assembled runtime is incomplete: $($runtimeState.missing -join ', ')"
    }
    $audit = Test-StillHungerContent $Paths.runtime $script:Project
    return [ordered]@{
        api = $api
        logs = $logs
        runtime = $runtimeState
        audit = $audit
        development = $developmentProfile
        inheritedProfile = @($inheritedProfile)
        textureConversion = $textureConversion
    }
}

function Test-Runtime {
    param([Parameter(Mandatory)][string]$Runtime)
    $required = @()
    foreach ($artifact in $script:Project.requiredArtifacts.engine) {
        $required += [string]$artifact
    }
    foreach ($artifact in $script:Project.requiredArtifacts.sdk) {
        $required += [string]$artifact
    }
    $required += @('rt/data/scenes.json', 'rt/data/textures.json', "$($script:Project.gameToken)/gameinfo.txt", 'valve/gameinfo.txt')
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
    $processes = @(Get-ExactRuntimeProcesses $executable)
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
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][DateTime]$StartTime,
        [Parameter(Mandatory)][string]$Executable
    )
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return 'already-exited' }
    $actualPath = $process.Path
    if (-not $actualPath.Equals([IO.Path]::GetFullPath($Executable), [StringComparison]::OrdinalIgnoreCase) -or
        [Math]::Abs(($process.StartTime - $StartTime).TotalSeconds) -gt 1) {
        throw "Refusing to stop PID $ProcessId because its identity no longer matches the process this command started."
    }
    $null = $process.CloseMainWindow()
    if (-not $process.WaitForExit(5000)) {
        Stop-Process -Id $ProcessId
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
    $arguments = @(Get-LaunchArguments $Kind)
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
        [Parameter(Mandatory)][string]$Kind,
        [string]$Map,
        [int]$Seconds = 0,
        [string]$RecordName = 'smoke.json',
        [string]$ReadyGraphBsp,
        [string]$ReadyGraphPath,
        [switch]$MenuOnly,
        [switch]$SkipAudit,
        [switch]$NoScreenshot
    )
    $state = Test-Runtime $Runtime
    if (-not $state.valid) { throw "Runtime is incomplete: $($state.missing -join ', ')" }
    $contentAudit = $null
    if (-not $SkipAudit) {
        $contentAudit = if ($Kind -in @('preprod', 'production', 'assembled')) {
            Test-StillHungerContent $Runtime $script:Project -Payload -AllowGenerated
        }
        else {
            Test-StillHungerContent $Runtime $script:Project
        }
    }
    Assert-RuntimeIdle $Runtime
    $exe = Join-Path $Runtime 'rt_bin\xash3d.exe'
    $arguments = @(Get-LaunchArguments $Kind)
    if ($MenuOnly) {
        $menuArguments = [Collections.Generic.List[string]]::new()
        for ($argumentIndex = 0; $argumentIndex -lt $arguments.Count; ++$argumentIndex) {
            if ($arguments[$argumentIndex] -ieq '+map') {
                ++$argumentIndex
                continue
            }
            $menuArguments.Add($arguments[$argumentIndex])
        }
        $arguments = @($menuArguments)
        $Map = 'menu-background'
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Map)) {
            $Map = [string]$script:Project.smoke.map
        }
        for ($argumentIndex = 0; $argumentIndex -lt ($arguments.Count - 1); ++$argumentIndex) {
            if ($arguments[$argumentIndex] -ieq '+map') {
                $arguments[$argumentIndex + 1] = $Map
                break
            }
        }
    }
    $log = Join-Path $Runtime 'engine.log'
    if (Test-Path -LiteralPath $log) { Remove-Item -LiteralPath $log -Force }
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $Runtime -PassThru
    $pidStarted = $process.Id
    $startTime = $process.StartTime
    if ($Seconds -le 0) {
        $Seconds = [int]$script:Project.smoke.seconds
    }
    $shot = $null
    try {
        for ($i = 0; $i -lt $Seconds; $i++) {
            Start-Sleep -Seconds 1
            $process.Refresh()
            if ($process.HasExited) { break }
            if ($ReadyGraphBsp -and $ReadyGraphPath -and
                (Test-CurrentNodeGraph $ReadyGraphBsp $ReadyGraphPath)) { break }
        }
        if ($Screenshots -and -not $NoScreenshot -and -not $process.HasExited) {
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
        $errorLines = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($pattern in $script:Project.releasePolicy.logFailurePatterns) {
            foreach ($match in Select-String -LiteralPath $log -Pattern ([string]$pattern)) {
                $null = $errorLines.Add($match.Line)
            }
        }
        $logErrors = @($errorLines)
    }
    $savedLog = $null
    if (Test-Path -LiteralPath $log) {
        $savedLog = Join-Path $StateRoot "logs\$($Map -replace '[^A-Za-z0-9_.-]', '_').log"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $savedLog) | Out-Null
        Copy-Item -LiteralPath $log -Destination $savedLog -Force
    }
    $success = ($exitBeforeCleanup -eq $null -or $exitBeforeCleanup -eq 0) -and $logErrors.Count -eq 0
    $record = [ordered]@{
        kind = $Kind
        success = $success
        runtime = $Runtime
        executable = $exe
        pid = $pidStarted
        startTime = $startTime.ToString('o')
        map = $Map
        arguments = $arguments
        observedSeconds = $Seconds
        exitBeforeCleanup = $exitBeforeCleanup
        cleanup = $cleanup
        audit = $contentAudit
        log = $savedLog
        logErrors = $logErrors
        screenshot = $shot
        finishedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonAtomic (Join-Path $StateRoot $RecordName) $record
    if (-not $success) { throw "Smoke test failed. See '$StateRoot\$RecordName'." }
    return $record
}

function Invoke-SmokeCampaign {
    if (-not [string]::IsNullOrWhiteSpace($Name) -and -not [string]::IsNullOrWhiteSpace($Release)) {
        throw "Use either -Name or -Release with 'smoke-campaign', not both."
    }

    $runtime = $null
    $stateRoot = $null
    $target = $null
    $payload = $false
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $feature = Get-Feature $Name
        $runtime = [string]$feature.paths.runtime
        $stateRoot = Join-Path (Get-FeatureRoot $Name) '.state\campaign-smoke'
        $target = "feature-$Name"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Release)) {
        $preprodStateFile = Join-Path $script:ProjectRoot '.state\preprod.json'
        if (-not (Test-Path -LiteralPath $preprodStateFile)) {
            throw 'No release is staged in preprod.'
        }
        $preprodState = Get-Content -LiteralPath $preprodStateFile -Raw | ConvertFrom-Json
        if ([string]$preprodState.release -ne $Release) {
            throw "Preprod contains release '$($preprodState.release)', not '$Release'."
        }
        $runtime = Resolve-ProjectPath $script:Project.paths.preprod
        $stateRoot = Join-Path $script:ProjectRoot '.state\preprod-campaign-smoke'
        $target = "preprod-$Release"
        $payload = $true
    }
    else {
        throw "-Name or -Release is required for 'smoke-campaign'."
    }

    $runtimeState = Test-Runtime $runtime
    if (-not $runtimeState.valid) {
        throw "Runtime is incomplete: $($runtimeState.missing -join ', ')"
    }
    $audit = if ($payload) {
        Test-StillHungerContent $runtime $script:Project -Payload -AllowGenerated
    }
    else {
        Test-StillHungerContent $runtime $script:Project
    }

    $seconds = [int]$script:Project.releasePolicy.campaignSmokeSeconds
    $results = [Collections.Generic.List[object]]::new()
    $currentMap = 'menu-background'
    try {
        $results.Add((Invoke-Smoke $runtime $stateRoot "$target-menu" -Seconds $seconds -RecordName 'menu.json' -MenuOnly -SkipAudit))
        foreach ($mapName in $script:Project.releasePolicy.campaignMaps) {
            $currentMap = [string]$mapName
            if ($currentMap -eq 'menu') { continue }
            $recordName = "maps\$currentMap.json"
            if ($currentMap -eq [string]$script:Project.smoke.map) {
                $results.Add((Invoke-Smoke $runtime $stateRoot "$target-$currentMap" -Map $currentMap -Seconds $seconds -RecordName $recordName -SkipAudit))
            }
            else {
                $results.Add((Invoke-Smoke $runtime $stateRoot "$target-$currentMap" -Map $currentMap -Seconds $seconds -RecordName $recordName -SkipAudit -NoScreenshot))
            }
        }
    }
    catch {
        Write-JsonAtomic (Join-Path $stateRoot 'campaign-smoke.json') ([ordered]@{
            success = $false
            target = $target
            runtime = $runtime
            audit = $audit
            completed = $results.Count
            failedMap = $currentMap
            error = $_.Exception.Message
            finishedUtc = [DateTime]::UtcNow.ToString('o')
        })
        throw
    }

    $record = [ordered]@{
        success = $true
        target = $target
        runtime = $runtime
        audit = $audit
        maps = $results.Count
        secondsPerMap = $seconds
        results = @($results)
        finishedUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonAtomic (Join-Path $stateRoot 'campaign-smoke.json') $record
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
        engine = Get-FeatureGitInfo $paths.engine 'engine'
        sdk = Get-FeatureGitInfo $paths.sdk 'sdk'
        rtgl1 = Get-FeatureGitInfo $paths.rtgl1 'rtgl1'
        content = Get-FeatureGitInfo $paths.runtime 'content'
        mainui = Get-GitInfo (Get-RepoPath 'mainui')
    }
    $stateRoot = Join-Path (Get-FeatureRoot $Name) '.state'
    $buildFile = Join-Path $stateRoot 'build.json'
    $smokeFile = Join-Path $stateRoot 'smoke.json'
    $build = if (Test-Path -LiteralPath $buildFile) { Get-Content $buildFile -Raw | ConvertFrom-Json } else { $null }
    $smoke = if (Test-Path -LiteralPath $smokeFile) { Get-Content $smokeFile -Raw | ConvertFrom-Json } else { $null }
    $behindMaster = @(
        foreach ($component in @('engine', 'sdk', 'rtgl1', 'content')) {
            if ([int]$repositories.$component.integration.behind -gt 0) {
                [ordered]@{
                    component = $component
                    commits = [int]$repositories.$component.integration.behind
                }
            }
        }
    )
    $buildCurrent = $false
    if ($build -and $build.success) {
        $buildCurrent = (
            [string]$build.commits.engine -eq [string]$repositories.engine.commit -and
            [string]$build.commits.sdk -eq [string]$repositories.sdk.commit -and
            [string]$build.commits.rtgl1 -eq [string]$repositories.rtgl1.commit -and
            [string]$build.commits.content -eq [string]$repositories.content.commit -and
            [string]$build.commits.mainui -eq [string]$repositories.mainui.commit
        )
    }
    $smokeCurrent = $false
    if ($buildCurrent -and $smoke -and $smoke.success) {
        try {
            $smokeCurrent = (
                (Convert-StateTimestampToUtc $smoke.finishedUtc) -ge
                (Convert-StateTimestampToUtc $build.builtUtc)
            )
        }
        catch {
            $smokeCurrent = $false
        }
    }
    $featureClean = -not @(
        @('engine', 'sdk', 'rtgl1', 'content') |
            Where-Object { [bool]$repositories.$_.dirty }
    )
    $mainuiClean = -not [bool]$repositories.mainui.dirty
    return [ordered]@{
        feature = $feature
        repositories = $repositories
        integration = [ordered]@{
            needsSync = ($behindMaster.Count -gt 0)
            behindMaster = $behindMaster
            featureClean = $featureClean
            mainuiClean = $mainuiClean
            buildCurrent = $buildCurrent
            smokeCurrent = $smokeCurrent
            readyToFinish = (
                $behindMaster.Count -eq 0 -and
                $featureClean -and
                $mainuiClean -and
                $buildCurrent -and
                $smokeCurrent
            )
        }
        api = Get-ApiState $paths.engine $paths.sdk
        runtime = Test-Runtime $paths.runtime
        build = $build
        smoke = $smoke
    }
}

function Invoke-SyncFeature {
    Require-FeatureName
    Enter-ProjectLock
    $feature = Get-Feature $Name
    $featureBranch = [string]$feature.branch
    $componentPaths = Get-FeatureComponentPaths $feature
    $before = [ordered]@{}

    foreach ($component in @('engine', 'sdk', 'rtgl1', 'content')) {
        $path = [string]$componentPaths.$component
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            throw "Feature $component worktree is missing: $path"
        }
        $info = Get-GitInfo $path
        if ([string]$info.branch -ne $featureBranch) {
            throw "Feature $component worktree is on '$($info.branch)', expected '$featureBranch'."
        }
        if ($info.dirty) {
            throw "Feature $component worktree is dirty: $path"
        }
        $canonical = Get-RepoPath $component
        if (-not (Test-GitClean $canonical)) {
            throw "Canonical $component repository is dirty."
        }
        $before[$component] = Get-BranchDivergence $path ([string]$script:Project.branches.$component)
    }

    $stateRoot = Join-Path (Get-FeatureRoot $Name) '.state'
    $buildFile = Join-Path $stateRoot 'build.json'
    $mainui = Get-RepoPath 'mainui'
    if (-not (Test-GitClean $mainui)) {
        throw 'Canonical mainui repository is dirty.'
    }
    $mainuiChangedSinceBuild = $false
    if (Test-Path -LiteralPath $buildFile -PathType Leaf) {
        $build = Get-Content -LiteralPath $buildFile -Raw | ConvertFrom-Json
        $mainuiCommit = Invoke-Git $mainui @('rev-parse', 'HEAD')
        $mainuiChangedSinceBuild = ([string]$build.commits.mainui -ne $mainuiCommit)
    }
    $needsSync = @(
        @('engine', 'sdk', 'rtgl1', 'content') |
            Where-Object { [int]$before.$_.behind -gt 0 }
    )
    $verificationInvalidated = @()
    if ($needsSync.Count -gt 0 -or $mainuiChangedSinceBuild) {
        $verificationInvalidated = @(Remove-FeatureVerification $stateRoot)
    }

    $changed = [Collections.Generic.List[string]]::new()
    foreach ($component in @('engine', 'sdk', 'rtgl1', 'content')) {
        if ([int]$before[$component].behind -eq 0) { continue }
        $path = [string]$componentPaths.$component
        $master = [string]$script:Project.branches.$component
        try {
            $null = Invoke-Git $path @('merge', '--no-edit', $master)
            $changed.Add($component)
        }
        catch {
            throw "Sync failed in '$component'. Resolve or abort the merge in '$path', then rerun sync. $($_.Exception.Message)"
        }
    }

    $after = [ordered]@{}
    foreach ($component in @('engine', 'sdk', 'rtgl1', 'content')) {
        $after[$component] = Get-BranchDivergence (
            [string]$componentPaths.$component
        ) ([string]$script:Project.branches.$component)
    }
    return [ordered]@{
        feature = $Name
        branch = $featureBranch
        changed = @($changed)
        alreadyCurrent = ($changed.Count -eq 0 -and -not $mainuiChangedSinceBuild)
        mainuiChangedSinceBuild = $mainuiChangedSinceBuild
        verificationInvalidated = $verificationInvalidated
        before = $before
        after = $after
    }
}

function Invoke-Audit {
    if (-not [string]::IsNullOrWhiteSpace($Name) -and -not [string]::IsNullOrWhiteSpace($Release)) {
        throw "Use either -Name or -Release with 'audit', not both."
    }

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $feature = Get-Feature $Name
        $runtime = [string]$feature.paths.runtime
        $runtimeState = Test-Runtime $runtime
        if (-not $runtimeState.valid) {
            throw "Feature runtime is incomplete: $($runtimeState.missing -join ', ')"
        }
        $audit = Test-StillHungerContent $runtime $script:Project
        Write-JsonAtomic (Join-Path (Get-FeatureRoot $Name) '.state\audit.json') $audit
        return $audit
    }

    if (-not [string]::IsNullOrWhiteSpace($Release)) {
        $releaseRoot = Join-Path (Resolve-ProjectPath $script:Project.paths.releases) $Release
        $payload = Join-Path $releaseRoot 'payload'
        if (-not (Test-Path -LiteralPath $payload -PathType Container)) {
            throw "Release '$Release' does not exist."
        }

        $result = [ordered]@{
            release = $Release
            payload = Test-StillHungerContent $payload $script:Project -Payload
            preprod = $null
        }
        $preprodStateFile = Join-Path $script:ProjectRoot '.state\preprod.json'
        if (Test-Path -LiteralPath $preprodStateFile) {
            $preprodState = Get-Content -LiteralPath $preprodStateFile -Raw | ConvertFrom-Json
            if ([string]$preprodState.release -eq $Release) {
                $result.preprod = Test-StillHungerContent (Resolve-ProjectPath $script:Project.paths.preprod) $script:Project -Payload -AllowGenerated
            }
        }
        Write-JsonAtomic (Join-Path $script:ProjectRoot ".state\audits\release-$Release.json") $result
        return $result
    }

    throw "-Name or -Release is required for 'audit'."
}

function Invoke-BuildFeature {
    Require-FeatureName
    Enter-ProjectLock
    $feature = Get-Feature $Name
    $paths = Get-BuildPaths $feature
    $stateRoot = Join-Path (Get-FeatureRoot $Name) '.state'
    if (-not (Test-GitClean (Get-RepoPath 'mainui'))) {
        throw 'Canonical mainui repository is dirty.'
    }
    $null = Remove-FeatureVerification $stateRoot
    $result = Invoke-BuildSet $paths $stateRoot -Development
    $commits = [ordered]@{
        engine = (Invoke-Git $paths.engine @('rev-parse', 'HEAD'))
        sdk = (Invoke-Git $paths.sdk @('rev-parse', 'HEAD'))
        rtgl1 = (Invoke-Git $paths.rtgl1 @('rev-parse', 'HEAD'))
        content = (Invoke-Git $paths.runtime @('rev-parse', 'HEAD'))
        mainui = (Invoke-Git (Join-Path $paths.engine '3rdparty\mainui') @('rev-parse', 'HEAD'))
    }
    $record = [ordered]@{
        success = $true
        builtUtc = [DateTime]::UtcNow.ToString('o')
        commits = $commits
        api = $result.api
        logs = $result.logs
        runtime = $result.runtime
        audit = $result.audit
        development = $result.development
        inheritedProfile = @($result.inheritedProfile)
        textureConversion = $result.textureConversion
        artifacts = @(
            foreach ($relative in @(
                'rt_bin\xash3d.exe',
                'rt_bin\xash.dll',
                'rt_bin\filesystem_stdio.dll',
                'rt_bin\ref_gl.dll',
                'rt_bin\menu.dll',
                'rt_bin\RayTracedGL1.dll',
                'rt_bin\SDL2.dll',
                "$($script:Project.gameToken)\cl_dlls\client_amd64.dll",
                "$($script:Project.gameToken)\dlls\einar_amd64.dll"
            )) {
                $file = Join-Path $paths.runtime $relative
                [ordered]@{
                    path = $relative.Replace('\', '/')
                    length = (Get-Item -LiteralPath $file).Length
                    sha256 = Get-FileSha256 $file
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

function Get-ReusableRelease {
    $releaseRoot = Resolve-ProjectPath $script:Project.paths.releases
    $current = [ordered]@{
        engine = Invoke-Git (Get-RepoPath 'engine') @('rev-parse', [string]$script:Project.branches.engine)
        sdk = Invoke-Git (Get-RepoPath 'sdk') @('rev-parse', [string]$script:Project.branches.sdk)
        rtgl1 = Invoke-Git (Get-RepoPath 'rtgl1') @('rev-parse', [string]$script:Project.branches.rtgl1)
        mainui = Invoke-Git (Get-RepoPath 'mainui') @('rev-parse', [string]$script:Project.branches.mainui)
        content = Invoke-Git (Get-RepoPath 'content') @('rev-parse', [string]$script:Project.branches.content)
    }

    $candidates = @(
        Get-ChildItem -LiteralPath $releaseRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object Name -Match '^\d+$' |
            Sort-Object { [int]$_.Name } -Descending
    )
    foreach ($candidate in $candidates) {
        $manifestFile = Join-Path $candidate.FullName 'release.json'
        $payload = Join-Path $candidate.FullName 'payload'
        if (-not (Test-Path -LiteralPath $manifestFile -PathType Leaf)) { continue }
        try {
            $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
            $matches = $true
            foreach ($component in $current.Keys) {
                if ([string]$manifest.commits.$component -cne [string]$current[$component]) {
                    $matches = $false
                    break
                }
            }
            if (-not $matches) { continue }

            $null = & git -C $script:ProjectRoot merge-base --is-ancestor ([string]$manifest.commits.orchestration) HEAD
            if ($LASTEXITCODE -ne 0) { continue }

            Assert-ReleaseHashes $manifest $payload
            Test-StillHungerContent $payload $script:Project -Payload | Out-Null
            return [string]$candidate.Name
        }
        catch {
            continue
        }
    }
    return $null
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
        if (Test-Path -LiteralPath $preprod) { Move-DirectoryAtomic $preprod $backup }
        Move-DirectoryAtomic $stage $preprod
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
    }
    catch {
        if (-not (Test-Path -LiteralPath $preprod) -and (Test-Path -LiteralPath $backup)) {
            Move-DirectoryAtomic $backup $preprod
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
    param(
        [Parameter(Mandatory)][string]$ReleaseId,
        [Parameter(Mandatory)][string]$FeatureRuntime
    )
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
        $textureConversion = $build.textureConversion
        $nodeGraphs = Update-ReleaseNodeGraphs $paths.runtime $stateRoot
        New-Item -ItemType Directory -Force -Path (Join-Path $staging 'payload') | Out-Null
        $payload = Join-Path $staging 'payload'
        Copy-DeployableTree $paths.runtime $payload
        $featureProfile = @(Copy-FeatureProfileToRelease $FeatureRuntime $payload)
        $runtime = Test-Runtime (Join-Path $staging 'payload')
        if (-not $runtime.valid) { throw "Release payload is incomplete: $($runtime.missing -join ', ')" }
        $audit = Test-StillHungerContent (Join-Path $staging 'payload') $script:Project -Payload
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
            textureConversion = $textureConversion
            nodeGraphs = $nodeGraphs
            featureProfile = @($featureProfile)
            audit = $audit
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
    $featureRoot = Get-FeatureRoot $Name
    $existingWorktrees = @(
        @($paths.engine, $paths.sdk, $paths.rtgl1, $paths.runtime) |
            Where-Object { Test-Path -LiteralPath $_ }
    )
    if ($existingWorktrees.Count -eq 0) {
        $preprodStateFile = Join-Path $script:ProjectRoot '.state\preprod.json'
        if (-not (Test-Path -LiteralPath $preprodStateFile)) {
            throw 'Feature worktrees are gone, but there is no verified preprod state to recover finish.'
        }
        $preprodState = Get-Content -LiteralPath $preprodStateFile -Raw | ConvertFrom-Json
        $releaseId = [string]$preprodState.release
        $releaseRoot = Join-Path (Resolve-ProjectPath $script:Project.paths.releases) $releaseId
        $manifestFile = Join-Path $releaseRoot 'release.json'
        if (-not (Test-Path -LiteralPath $manifestFile)) {
            throw "Feature worktrees are gone, but release '$releaseId' is incomplete."
        }
        foreach ($component in @('engine', 'sdk', 'rtgl1', 'content')) {
            $repo = Get-RepoPath $component
            $null = & git -C $repo show-ref --verify --quiet "refs/heads/$($feature.branch)"
            if ($LASTEXITCODE -eq 0) {
                throw "Feature worktrees are gone, but branch '$($feature.branch)' still exists in $component."
            }
        }
        $preprod = Resolve-ProjectPath $script:Project.paths.preprod
        $runtimeState = Test-Runtime $preprod
        if (-not $runtimeState.valid) {
            throw "Recovered preprod is incomplete: $($runtimeState.missing -join ', ')"
        }
        $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
        Assert-ReleaseHashes $manifest $preprod
        $finished = [ordered]@{}
        foreach ($property in $feature.PSObject.Properties) {
            $finished[$property.Name] = $property.Value
        }
        $finished['status'] = 'finished'
        $finished['finishedUtc'] = [DateTime]::UtcNow.ToString('o')
        $finished['release'] = $releaseId
        $archiveRecord = Assert-ProjectPath (Join-Path $script:ProjectRoot ".state\finished\$Name.json")
        Write-JsonAtomic $archiveRecord $finished
        Remove-Item -LiteralPath $featureRoot -Recurse -Force
        return [ordered]@{
            recovered = $true
            release = $releaseId
            preprod = $preprod
            archivedFeature = $archiveRecord
        }
    }
    if ($existingWorktrees.Count -ne 4) {
        throw 'Only some feature worktrees exist; refusing automatic finish recovery.'
    }
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
    if (-not (Test-GitClean (Get-RepoPath 'mainui'))) {
        throw 'Canonical mainui repository is dirty.'
    }
    $componentPaths = Get-FeatureComponentPaths $feature
    foreach ($component in @('engine', 'sdk', 'rtgl1', 'content')) {
        $divergence = Get-BranchDivergence (
            [string]$componentPaths.$component
        ) ([string]$script:Project.branches.$component)
        if ([int]$divergence.behind -gt 0) {
            throw "$component feature is behind master by $($divergence.behind) commit(s). Run 'tools\StillHunger.cmd sync -Name $Name', rebuild, and smoke-test again."
        }
    }
    $build = Get-Content -LiteralPath $buildFile -Raw | ConvertFrom-Json
    foreach ($component in @('engine', 'sdk', 'rtgl1')) {
        $actual = Invoke-Git $paths.$component @('rev-parse', 'HEAD')
        if ($actual -ne $build.commits.$component) { throw "$component changed after the last build." }
    }
    $contentActual = Invoke-Git $paths.runtime @('rev-parse', 'HEAD')
    if ($contentActual -ne $build.commits.content) { throw 'Content changed after the last build.' }
    $mainuiActual = Invoke-Git (Get-RepoPath 'mainui') @('rev-parse', 'HEAD')
    if ($mainuiActual -ne $build.commits.mainui) { throw 'mainui changed after the last build.' }
    try {
        $smokeAfterBuild = (
            (Convert-StateTimestampToUtc $smoke.finishedUtc) -ge
            (Convert-StateTimestampToUtc $build.builtUtc)
        )
    }
    catch {
        $smokeAfterBuild = $false
    }
    if (-not $smokeAfterBuild) {
        throw 'The feature smoke test is older than the current build. Run smoke-feature again.'
    }

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
        $releaseId = Get-ReusableRelease
        if ($releaseId) {
            $releaseRoot = Join-Path (Resolve-ProjectPath $script:Project.paths.releases) $releaseId
            $preprod = Stage-Preprod $releaseId
            $releaseResult = [ordered]@{
                release = $releaseId
                path = $releaseRoot
                manifest = Join-Path $releaseRoot 'release.json'
                preprod = $preprod
                recovered = $true
            }
        }
        else {
            $releaseId = Get-NextReleaseId
            $releaseResult = New-CleanRelease $releaseId ([string]$paths.runtime)
        }
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
    $finished = [ordered]@{}
    foreach ($property in $feature.PSObject.Properties) {
        $finished[$property.Name] = $property.Value
    }
    $finished['status'] = 'finished'
    $finished['finishedUtc'] = [DateTime]::UtcNow.ToString('o')
    $finished['release'] = $releaseResult.release
    $archiveRecord = Assert-ProjectPath (Join-Path $script:ProjectRoot ".state\finished\$Name.json")
    Write-JsonAtomic $archiveRecord $finished
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
        $hash = Get-FileSha256 $file
        if ($hash -cne [string]$entry.sha256) { $errors.Add("hash:$relative") }
    }
    if ($errors.Count -gt 0) { throw "Release hash verification failed: $($errors -join ', ')" }
}

function New-UserProfileArchive {
    param(
        [Parameter(Mandatory)][string]$Production,
        [Parameter(Mandatory)][string]$ReleaseId
    )

    if (-not (Test-Path -LiteralPath $Production -PathType Container)) { return $null }

    $archivesRoot = Resolve-ProjectPath $script:Project.paths.archives
    $archiveRoot = Assert-ProjectPath (Join-Path $archivesRoot "profile-before-release-$ReleaseId-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))")
    New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null

    foreach ($entry in $script:Project.userOwned) {
        $pattern = [string]$entry
        if ($pattern.EndsWith('/**')) {
            $relative = $pattern.Substring(0, $pattern.Length - 3)
            $source = Join-Path $Production ($relative -replace '/', '\')
            if (Test-Path -LiteralPath $source -PathType Container) {
                Copy-Tree $source (Join-Path $archiveRoot ($relative -replace '/', '\'))
            }
        }
        else {
            $source = Join-Path $Production ($pattern -replace '/', '\')
            if (Test-Path -LiteralPath $source -PathType Leaf) {
                $target = Join-Path $archiveRoot ($pattern -replace '/', '\')
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
                Copy-Item -LiteralPath $source -Destination $target -Force
            }
        }
    }

    $inventory = @(Get-HashInventory $archiveRoot)
    Write-JsonAtomic (Join-Path $archiveRoot 'archive.json') ([ordered]@{
        schemaVersion = 1
        purpose = 'Pre-promotion user profile snapshot'
        release = $ReleaseId
        source = $Production
        createdUtc = [DateTime]::UtcNow.ToString('o')
        files = $inventory
    })
    return [ordered]@{
        path = $archiveRoot
        files = $inventory.Count
    }
}

function Set-CleanConfigFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$EnsureCheatsOff
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

    $output = [Collections.Generic.List[string]]::new()
    $hasCheatSetting = $false
    $progressCvars = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $script:Project.releasePolicy.resetProgressCvars) {
        $null = $progressCvars.Add([string]$name)
    }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*sv_cheats\s+') {
            $output.Add('sv_cheats 0')
            $hasCheatSetting = $true
            continue
        }
        if ($line -match '^\s*cl_trace_messages\s+') { continue }
        if ($line -match '^\s*bind\s+"?[^"\s]+"?\s+"?(impulse\s+101|noclip|th_give_startitems)"?\s*$') { continue }
        if ($line -match '^\s*"?([A-Za-z_][A-Za-z0-9_]*)"?\s+' -and
            $progressCvars.Contains($Matches[1])) { continue }
        $output.Add($line)
    }
    if ($EnsureCheatsOff -and -not $hasCheatSetting) {
        $output.Insert(0, 'sv_cheats 0')
    }
    foreach ($name in $script:Project.releasePolicy.resetProgressCvars) {
        $output.Add("$name `"0`"")
    }
    [IO.File]::WriteAllLines($Path, @($output), [Text.UTF8Encoding]::new($false))
    return $true
}

function Invoke-SurgicalProfileCleanup {
    param([Parameter(Mandatory)][string]$Runtime)

    $changed = [Collections.Generic.List[string]]::new()
    $rendererConfig = Join-Path $Runtime 'RayTracedGL1.json'
    if (Test-Path -LiteralPath $rendererConfig -PathType Leaf) {
        try {
            $renderer = Get-Content -LiteralPath $rendererConfig -Raw | ConvertFrom-Json
            if ($renderer.PSObject.Properties['developerMode']) {
                $renderer.developerMode = $false
            }
            else {
                $renderer | Add-Member -NotePropertyName developerMode -NotePropertyValue $false
            }
            Write-JsonAtomic $rendererConfig $renderer
            $changed.Add('RayTracedGL1.json')
        }
        catch {
            throw "Could not sanitize renderer profile '$rendererConfig': $($_.Exception.Message)"
        }
    }

    $gameRoot = Join-Path $Runtime $script:Project.gameToken
    $userConfig = Join-Path $gameRoot 'userconfig.cfg'
    if (Set-CleanConfigFile $userConfig -EnsureCheatsOff) {
        $changed.Add("$($script:Project.gameToken)/userconfig.cfg")
    }
    $config = Join-Path $gameRoot 'config.cfg'
    if (Set-CleanConfigFile $config) {
        $changed.Add("$($script:Project.gameToken)/config.cfg")
    }

    $history = Join-Path $gameRoot 'console_history.txt'
    if (Test-Path -LiteralPath $history -PathType Leaf) {
        Remove-Item -LiteralPath $history -Force
        $changed.Add("$($script:Project.gameToken)/console_history.txt")
    }

    return [ordered]@{
        changed = @($changed)
    }
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
    $productionStateFile = Join-Path $script:ProjectRoot '.state\production.json'
    $previousRelease = $null
    if (Test-Path -LiteralPath $productionStateFile) {
        $previousState = Get-Content -LiteralPath $productionStateFile -Raw | ConvertFrom-Json
        if ([string]$previousState.production -eq $production) {
            $previousRelease = [string]$previousState.release
        }
    }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    $parent = Split-Path -Parent $production
    $stage = Join-Path $parent ".$([IO.Path]::GetFileName($production)).staging-$Release"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    Copy-Tree $payload $stage
    Assert-ReleaseHashes $manifest $stage
    $promotionAudit = Test-StillHungerContent $stage $script:Project -Payload
    $profileArchive = New-UserProfileArchive $production $Release
    if (Test-Path -LiteralPath $production) {
        foreach ($entry in $script:Project.userOwned) {
            $pattern = [string]$entry
            if (Test-FeatureProfile $pattern) { continue }
            if (Test-ResetOnPromote $pattern) { continue }
            if ($pattern.EndsWith('/**')) {
                $relative = $pattern.Substring(0, $pattern.Length - 3)
                $source = Join-Path $production ($relative -replace '/', '\')
                if (Test-Path -LiteralPath $source -PathType Container) {
                    $target = Join-Path $stage ($relative -replace '/', '\')
                    if (Test-Path -LiteralPath $target) {
                        $stagePrefix = [IO.Path]::GetFullPath($stage).TrimEnd('\') + '\'
                        $targetPath = [IO.Path]::GetFullPath($target)
                        if (-not $targetPath.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                            throw "User-owned staging path escaped the sibling stage: $targetPath"
                        }
                        Remove-Item -LiteralPath $targetPath -Recurse -Force
                    }
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
    $profileCleanup = Invoke-SurgicalProfileCleanup $stage
    Assert-ReleaseHashes $manifest $stage -IgnoreUserOwned
    $backup = $null
    try {
        if (Test-Path -LiteralPath $production) {
            $backup = "$production.rollback-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
            Move-DirectoryAtomic $production $backup
        }
        Move-DirectoryAtomic $stage $production
    }
    catch {
        if (-not (Test-Path -LiteralPath $production) -and $backup -and (Test-Path -LiteralPath $backup)) {
            Move-DirectoryAtomic $backup $production
        }
        throw
    }
    $record = [ordered]@{
        release = $Release
        production = $production
        previous = $backup
        previousRelease = $previousRelease
        promotedUtc = [DateTime]::UtcNow.ToString('o')
        manifest = $manifestFile
        audit = $promotionAudit
        profileArchive = $profileArchive
        profileCleanup = $profileCleanup
    }
    Write-JsonAtomic $productionStateFile $record
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
    if (Test-Path -LiteralPath $production) { Move-DirectoryAtomic $production $failed }
    try {
        Move-DirectoryAtomic $previous $production
    }
    catch {
        if (-not (Test-Path -LiteralPath $production) -and (Test-Path -LiteralPath $failed)) {
            Move-DirectoryAtomic $failed $production
        }
        throw
    }
    $record = [ordered]@{
        production = $production
        release = [string]$state.previousRelease
        restoredFrom = $previous
        displaced = $failed
        displacedRelease = [string]$state.release
        rolledBackUtc = [DateTime]::UtcNow.ToString('o')
    }
    Write-JsonAtomic (Join-Path $script:ProjectRoot '.state\rollback.json') $record
    Write-JsonAtomic $stateFile ([ordered]@{
        release = [string]$state.previousRelease
        production = $production
        previous = $failed
        previousRelease = [string]$state.release
        promotedUtc = [DateTime]::UtcNow.ToString('o')
        manifest = $null
        restoredByRollback = $true
    })
    return $record
}

try {
    $result = switch ($Command) {
        'new' { Invoke-NewFeature }
        'sources' { Invoke-PublicSources }
        'build-code' { Invoke-PublicCodeBuild }
        'assemble' { Invoke-PublicAssemble -Resources $Resources -Output $Output }
        'smoke-assembled' {
            Enter-ProjectLock
            $runtime = Get-PublicRuntimePath $Output
            Invoke-Smoke $runtime (Join-Path $script:ProjectRoot '.state\assembled-smoke') 'assembled'
        }
        'status' { Invoke-Status }
        'sync' { Invoke-SyncFeature }
        'build' { Invoke-BuildFeature }
        'audit' {
            Enter-ProjectLock
            Invoke-Audit
        }
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
        'smoke-campaign' {
            Enter-ProjectLock
            Invoke-SmokeCampaign
        }
        'finish' { Invoke-Finish }
        'hotfix-defaults' { Invoke-HotfixDefaults }
        'test-hotfix' { . (Join-Path $PSScriptRoot 'Test-StillHunger-Hotfix.ps1') }
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
