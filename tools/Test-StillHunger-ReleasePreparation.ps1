[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:Project = Get-Content -LiteralPath (Join-Path $root 'project.json') -Raw | ConvertFrom-Json
$tool = Join-Path $PSScriptRoot 'StillHunger.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($tool, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Release script has PowerShell parser errors: $($errors -join '; ')" }

# Load only pure helpers; the unified command entry point must never run in this test.
foreach ($name in @('Test-ResetOnPromote', 'Test-MapHasNavigationNodes', 'Test-CurrentNodeGraph', 'Set-CleanConfigFile')) {
    $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Release helper is missing: $name" }
    Invoke-Expression $definition.Extent.Text
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "StillHunger-ReleasePreparation-$PID-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
try {
    $config = Join-Path $temporaryRoot 'config.cfg'
    [IO.File]::WriteAllLines($config, @(
        'hud_tutorials_seen "63"',
        'sh_guide_weapons_unlocked "32767"',
        'sh_bestiary_unlocked "255"',
        'hud_tutorials "0"',
        'ui_scale "0.8"'
    ))
    $null = Set-CleanConfigFile $config
    $first = Get-Content -LiteralPath $config -Raw
    $null = Set-CleanConfigFile $config
    $second = Get-Content -LiteralPath $config -Raw
    Assert-True ($first -ceq $second) 'Release config cleanup must be repeatable.'
    foreach ($name in $script:Project.releasePolicy.resetProgressCvars) {
        $matches = @((Get-Content -LiteralPath $config) | Where-Object { $_ -match "^$name `"0`"$" })
        Assert-True ($matches.Count -eq 1) "Progress must reset once: $name"
    }
    Assert-True ($second.Contains('hud_tutorials "0"')) 'Tutorial preference must be preserved.'
    Assert-True ($second.Contains('ui_scale "0.8"')) 'Unrelated UI settings must be preserved.'
    Assert-True (Test-ResetOnPromote 'HungerRedux/SAVE/**') 'Save preservation pattern must be skipped during promotion.'
    Assert-True (Test-ResetOnPromote 'HungerRedux/SAVE/autosave.sav') 'Saved games must be skipped during promotion.'
    Assert-True (-not (Test-ResetOnPromote 'HungerRedux/config.cfg')) 'Other profile settings must remain preserved.'

    $bsp = Join-Path $temporaryRoot 'map.bsp'
    $graph = Join-Path $temporaryRoot 'map.nod'
    $entities = [Text.Encoding]::ASCII.GetBytes('{"classname" "info_node"}')
    $bytes = [byte[]]::new(124 + $entities.Length)
    [BitConverter]::GetBytes([int]30).CopyTo($bytes, 0)
    [BitConverter]::GetBytes([int]124).CopyTo($bytes, 4)
    [BitConverter]::GetBytes([int]$entities.Length).CopyTo($bytes, 8)
    $entities.CopyTo($bytes, 124)
    [IO.File]::WriteAllBytes($bsp, $bytes)
    Assert-True (Test-MapHasNavigationNodes $bsp) 'Maps with info_node must rebuild a graph.'
    $entities = [Text.Encoding]::ASCII.GetBytes('{"classname" "worldspawn"}')
    $bytes = [byte[]]::new(124 + $entities.Length)
    [BitConverter]::GetBytes([int]30).CopyTo($bytes, 0)
    [BitConverter]::GetBytes([int]124).CopyTo($bytes, 4)
    [BitConverter]::GetBytes([int]$entities.Length).CopyTo($bytes, 8)
    $entities.CopyTo($bytes, 124)
    [IO.File]::WriteAllBytes($bsp, $bytes)
    Assert-True (-not (Test-MapHasNavigationNodes $bsp)) 'Maps without navigation nodes must be skipped.'

    [IO.File]::WriteAllBytes($graph, [BitConverter]::GetBytes([int]$script:Project.releasePolicy.nodeGraphVersion))
    [IO.File]::SetLastWriteTimeUtc($graph, [IO.File]::GetLastWriteTimeUtc($bsp).AddSeconds(10))
    Assert-True (Test-CurrentNodeGraph $bsp $graph) 'Matching graph version and timestamp must pass.'
    [IO.File]::WriteAllBytes($graph, [BitConverter]::GetBytes([int]16))
    Assert-True (-not (Test-CurrentNodeGraph $bsp $graph)) 'Old graph version must fail.'
    [IO.File]::WriteAllBytes($graph, [BitConverter]::GetBytes([int]$script:Project.releasePolicy.nodeGraphVersion))
    [IO.File]::SetLastWriteTimeUtc($graph, [IO.File]::GetLastWriteTimeUtc($bsp).AddSeconds(-10))
    Assert-True (-not (Test-CurrentNodeGraph $bsp $graph)) 'Graph older than its BSP must fail.'

    $source = Get-Content -LiteralPath $tool -Raw
    Assert-True ($source.Contains('Update-ReleaseNodeGraphs $paths.runtime $stateRoot')) 'Clean releases must regenerate node graphs.'
    Assert-True ($source.Contains('if (Test-ResetOnPromote $pattern) { continue }')) 'Promotion must omit resettable saves.'
    @{ success = $true; tests = @('progress reset', 'settings preserved', 'save omission', 'node detection', 'graph freshness', 'release wiring') } | ConvertTo-Json
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
}
