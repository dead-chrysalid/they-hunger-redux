[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$project = Get-Content -LiteralPath (Join-Path $root 'project.json') -Raw | ConvertFrom-Json
$tool = Join-Path $PSScriptRoot 'StillHunger.ps1'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$tokens = $null
$errors = $null
[Management.Automation.Language.Parser]::ParseFile($tool, [ref]$tokens, [ref]$errors) | Out-Null
Assert-True ($errors.Count -eq 0) "StillHunger.ps1 has parser errors."
Assert-True ([int]$project.api.clientDll -eq 10) 'Client API authority must remain 10.'
Assert-True ([int]$project.api.renderer -eq 4) 'Renderer API authority must remain 4.'
Assert-True ([IO.Path]::IsPathRooted([string]$project.paths.production)) 'Production path must be absolute.'
Assert-True ([string]$project.paths.production -ne 'D:/Games/Xash3d') 'Legacy production path must not remain active.'
Assert-True ($project.requiredArtifacts.engine -contains 'rt_bin/menu.dll') 'Complete engine runtime must include rt_bin/menu.dll.'
Assert-True ($project.requiredArtifacts.sdk.Count -eq 2) 'Both SDK DLLs must be required.'
Assert-True ($project.releaseExclusions -contains '.workspace/**') 'Workspace-only content must be excluded from releases.'
Assert-True ($project.releaseExclusions -contains 'rt/mat_dev/**') 'Editable texture sources must be excluded from releases.'
Assert-True ($project.releaseExclusions -contains 'rt/scenes/**/mat_junction/**') 'Blender texture junctions must be excluded from releases.'
Assert-True ($project.userOwned -contains 'StillHunger/SAVE/**') 'Saves must be user-owned.'
Assert-True ($project.development.launchArguments -contains '-dev') 'Feature launches must enable engine developer mode.'
Assert-True ([bool]$project.development.renderer.developerMode) 'Feature renderer developer mode must be enabled.'
Assert-True (-not [bool]$project.development.renderer.developerWindow) 'Feature renderer developer window must default to disabled for OptiScaler compatibility.'
Assert-True ($project.development.gameCommands -contains 'sv_cheats 1') 'Feature profiles must enable cheats for authoring.'

$unsafe = Select-String -LiteralPath $tool -Pattern 'D:\\Games\\Xash3d|D:/Games/Xash3d'
Assert-True ($null -eq $unsafe) 'Project tool must not contain the legacy production path.'
$conversion = Select-String -LiteralPath $tool -Pattern 'Invoke-TextureConversion'
Assert-True ($null -ne $conversion) 'Release workflow must invoke texture conversion.'

[ordered]@{
    success = $true
    tests = @(
        'PowerShell syntax',
        'API authority',
        'production isolation',
        'complete artifact contract',
        'release exclusions',
        'feature authoring profile',
        'release texture conversion',
        'user-owned saves',
        'no legacy deployment path'
    )
} | ConvertTo-Json -Depth 5
