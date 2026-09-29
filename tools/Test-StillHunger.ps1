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
Assert-True ($project.userOwned -contains 'HungerRedux/SAVE/**') 'Saves must be user-owned.'
Assert-True ($project.featureProfile -contains 'HungerRedux/config.cfg') 'Feature releases must carry the tuned config profile.'
foreach ($profileFile in $project.featureProfile) {
    Assert-True ($project.userOwned -contains [string]$profileFile) "Feature profile file must also be user-owned: $profileFile"
}
Assert-True ($project.development.launchArguments -notcontains '-dev') 'Feature launches must keep engine developer logging disabled.'
Assert-True (-not [bool]$project.development.renderer.developerMode) 'Feature renderer developer logging must be disabled.'
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
$syncCommand = Select-String -LiteralPath $tool -SimpleMatch -Pattern "'sync' { Invoke-SyncFeature }"
Assert-True ($null -ne $syncCommand) 'Feature workflow must expose the sync command.'
$divergenceStatus = Select-String -LiteralPath $tool -Pattern 'needsSync|behindMaster|readyToFinish'
Assert-True ($divergenceStatus.Count -ge 3) 'Feature status must report integration readiness.'
$behindMasterGate = Select-String -LiteralPath $tool -SimpleMatch -Pattern 'feature is behind master'
Assert-True ($null -ne $behindMasterGate) 'Finish must reject features behind master.'
$smokeFreshnessGate = Select-String -LiteralPath $tool -SimpleMatch -Pattern 'smoke test is older than the current build'
Assert-True ($null -ne $smokeFreshnessGate) 'Finish must reject stale feature smoke evidence.'
$dependencyVerification = Select-String -LiteralPath $tool -Pattern 'Assert-DependencyInventory'
Assert-True ($null -ne $dependencyVerification) 'Release workflow must verify the pinned texture dependency.'
$developmentUriRule = Select-String -LiteralPath $auditTool -SimpleMatch -Pattern "StartsWith('mat_junction/'"
Assert-True ($null -ne $developmentUriRule) 'Payload audit must recognize development-only mat_junction URIs.'
$productionPayloadAudit = Select-String -LiteralPath $tool -SimpleMatch -Pattern "'preprod', 'production'"
Assert-True ($null -ne $productionPayloadAudit) 'Preprod and production smoke tests must use the same payload audit mode.'
$featureProfileCapture = Select-String -LiteralPath $tool -Pattern 'Copy-ProductionProfileDefaults|Copy-FeatureProfileToRelease|Test-FeatureProfile'
Assert-True ($featureProfileCapture.Count -ge 3) 'Feature profiles must inherit, enter the release payload, and take precedence during promotion.'

[ordered]@{
    success = $true
    tests = @(
        'PowerShell syntax',
        'API authority',
        'production isolation',
        'complete artifact contract',
        'release exclusions',
        'feature authoring profile',
        'feature master synchronization',
        'integration readiness reporting',
        'finish freshness gates',
        'pinned texture toolchain',
        'release texture conversion',
        'development-only glTF URI policy',
        'production payload audit mode',
        'feature profile release persistence',
        'user-owned saves',
        'no legacy deployment path'
    )
} | ConvertTo-Json -Depth 5
