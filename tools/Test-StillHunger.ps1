[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$project = Get-Content -LiteralPath (Join-Path $root 'project.json') -Raw | ConvertFrom-Json
$tool = Join-Path $PSScriptRoot 'StillHunger.ps1'
$auditTool = Join-Path $PSScriptRoot 'StillHunger.ContentAudit.ps1'

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
Assert-True ([string]$project.textureAuthoring.script -eq 'tools/CreateKTX2.py') 'Texture conversion must use the project-level tool.'
Assert-True ([string]$project.textureAuthoring.python -eq 'tools/.venv/Scripts/python.exe') 'Texture conversion must use the project-local Python environment.'
Assert-True ([string]$project.textureAuthoring.dependency -eq 'compressonator') 'Texture conversion must use the pinned Compressonator dependency.'
Assert-True ([string]$project.dependencies.compressonator.version -eq '4.5.52') 'Compressonator must remain pinned to the reviewed version.'
Assert-True (Test-Path -LiteralPath (Join-Path $root 'tools\Setup-TextureTools.cmd') -PathType Leaf) 'Texture toolchain setup wrapper must exist.'

$unsafe = Select-String -LiteralPath $tool -Pattern 'D:\\Games\\Xash3d|D:/Games/Xash3d'
Assert-True ($null -eq $unsafe) 'Project tool must not contain the legacy production path.'
$conversion = Select-String -LiteralPath $tool -Pattern 'Invoke-TextureConversion'
Assert-True ($null -ne $conversion) 'Release workflow must invoke texture conversion.'
$dependencyVerification = Select-String -LiteralPath $tool -Pattern 'Assert-DependencyInventory'
Assert-True ($null -ne $dependencyVerification) 'Release workflow must verify the pinned texture dependency.'
$developmentUriRule = Select-String -LiteralPath $auditTool -SimpleMatch -Pattern "StartsWith('mat_junction/'"
Assert-True ($null -ne $developmentUriRule) 'Payload audit must recognize development-only mat_junction URIs.'

[ordered]@{
    success = $true
    tests = @(
        'PowerShell syntax',
        'API authority',
        'production isolation',
        'complete artifact contract',
        'release exclusions',
        'feature authoring profile',
        'pinned texture toolchain',
        'release texture conversion',
        'development-only glTF URI policy',
        'user-owned saves',
        'no legacy deployment path'
    )
} | ConvertTo-Json -Depth 5
