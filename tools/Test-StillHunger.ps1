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
Assert-True ($project.userOwned -contains 'StillHunger/SAVE/**') 'Saves must be user-owned.'

$unsafe = Select-String -LiteralPath $tool -Pattern 'D:\\Games\\Xash3d|D:/Games/Xash3d'
Assert-True ($null -eq $unsafe) 'Project tool must not contain the legacy production path.'

[ordered]@{
    success = $true
    tests = @(
        'PowerShell syntax',
        'API authority',
        'production isolation',
        'complete artifact contract',
        'release exclusions',
        'user-owned saves',
        'no legacy deployment path'
    )
} | ConvertTo-Json -Depth 5
