[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$project = Get-Content -LiteralPath (Join-Path $projectRoot 'project.json') -Raw | ConvertFrom-Json
$authoring = $project.textureAuthoring
$dependencyName = [string]$authoring.dependency
$dependency = $project.dependencies.$dependencyName
if (-not $dependency) {
    throw "Unknown texture dependency '$dependencyName'."
}

function Resolve-ProjectPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([IO.Path]::IsPathRooted($Path)) {
        return [IO.Path]::GetFullPath($Path)
    }
    return [IO.Path]::GetFullPath((Join-Path $projectRoot $Path))
}

function Get-HashInventory {
    param([Parameter(Mandatory)][string]$Root)
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return @(
        Get-ChildItem -LiteralPath $rootPath -Recurse -Force -File |
            Sort-Object FullName |
            ForEach-Object {
                [pscustomobject]@{
                    Path = $_.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
                    Length = [long]$_.Length
                    SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
    )
}

function Assert-Inventory {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Manifest
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Dependency folder is missing: $Root"
    }
    if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
        throw "Dependency manifest is missing: $Manifest"
    }
    $expected = @(
        Import-Csv -LiteralPath $Manifest |
            ForEach-Object {
                [pscustomobject]@{
                    Path = [string]$_.Path
                    Length = [long]$_.Length
                    SHA256 = ([string]$_.SHA256).ToLowerInvariant()
                }
            }
    )
    $actual = @(Get-HashInventory $Root)
    if ($actual.Count -ne $expected.Count) {
        throw "Dependency inventory count mismatch: expected $($expected.Count), found $($actual.Count)."
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        $wanted = $expected[$index]
        $found = $actual[$index]
        if ($wanted.Path -cne $found.Path -or
            $wanted.Length -ne $found.Length -or
            $wanted.SHA256 -cne $found.SHA256) {
            throw "Dependency inventory mismatch at '$($wanted.Path)'."
        }
    }
    return $actual
}

$dependencyRoot = Resolve-ProjectPath ([string]$dependency.path)
$manifest = Resolve-ProjectPath ([string]$dependency.manifest)
$downloaded = $false
$temporaryRoot = $null

try {
    if (-not (Test-Path -LiteralPath $dependencyRoot -PathType Container)) {
        $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
            "StillHunger-Compressonator-$PID-$([Guid]::NewGuid().ToString('N'))"
        )
        $archive = Join-Path $temporaryRoot 'compressonator.zip'
        $expanded = Join-Path $temporaryRoot 'expanded'
        $staging = Join-Path $temporaryRoot 'runtime'
        New-Item -ItemType Directory -Force -Path $temporaryRoot, $expanded, $staging | Out-Null

        Invoke-WebRequest -Uri ([string]$dependency.archiveUrl) -OutFile $archive
        $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($archiveHash -cne ([string]$dependency.archiveSha256).ToLowerInvariant()) {
            throw "Compressonator archive hash mismatch. Expected $($dependency.archiveSha256), found $archiveHash."
        }

        Expand-Archive -LiteralPath $archive -DestinationPath $expanded
        $archiveRoot = Join-Path $expanded ([string]$dependency.archiveRoot)
        if (-not (Test-Path -LiteralPath $archiveRoot -PathType Container)) {
            throw "Compressonator archive root is missing: $archiveRoot"
        }
        Get-ChildItem -LiteralPath $archiveRoot -File |
            Copy-Item -Destination $staging -Force
        foreach ($folder in $dependency.runtimeFolders) {
            $source = Join-Path $archiveRoot ([string]$folder)
            if (-not (Test-Path -LiteralPath $source -PathType Container)) {
                throw "Required Compressonator folder is missing from the archive: $folder"
            }
            Copy-Item -LiteralPath $source -Destination $staging -Recurse
        }

        $null = Assert-Inventory $staging $manifest
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dependencyRoot) | Out-Null
        Move-Item -LiteralPath $staging -Destination $dependencyRoot
        $downloaded = $true
    }

    $inventory = @(Assert-Inventory $dependencyRoot $manifest)
    $python = Resolve-ProjectPath ([string]$authoring.python)
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
        $launcher = @(
            Get-Command 'py.exe' -CommandType Application -ErrorAction SilentlyContinue
        ) | Select-Object -First 1
        if (-not $launcher) {
            throw "Python $($authoring.pythonVersion) is required to create the texture-tools environment."
        }
        $venv = Split-Path -Parent (Split-Path -Parent $python)
        & $launcher.Source "-$($authoring.pythonVersion)" -m venv $venv
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $python -PathType Leaf)) {
            throw "Failed to create the texture-tools Python environment at '$venv'."
        }
    }

    $pythonVersion = (& $python --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $pythonVersion -notmatch "^Python $([regex]::Escape([string]$authoring.pythonVersion))(\.|$)") {
        throw "Unexpected texture-tools Python version: $pythonVersion"
    }
    $compressor = Join-Path $dependencyRoot 'compressonatorcli.exe'
    $compressorVersion = (& $compressor -version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $compressorVersion -notmatch [regex]::Escape([string]$dependency.version)) {
        throw "Unexpected Compressonator version: $compressorVersion"
    }

    [ordered]@{
        success = $true
        dependency = $dependencyName
        dependencyPath = $dependencyRoot
        dependencyVersion = [string]$dependency.version
        files = $inventory.Count
        downloaded = $downloaded
        python = $python
        pythonVersion = $pythonVersion
        compressor = $compressor
        compressorVersion = $compressorVersion
    } | ConvertTo-Json -Depth 5
}
finally {
    if ($temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
