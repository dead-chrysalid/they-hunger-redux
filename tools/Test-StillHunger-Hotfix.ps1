Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fixture = Assert-ProjectPath (Join-Path (Resolve-ProjectPath $script:Project.paths.work) (
    '.hotfix-test-' + [Guid]::NewGuid().ToString('N')
))
function Assert-HotfixTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Invoke-HotfixTest {
    param([string]$TestName, [string]$Json, [switch]$Fails)
    [IO.File]::WriteAllText((Join-Path $fixture 'settings.json'), $Json)
    $output = @(& (Join-Path $fixture 'tools\StillHunger.cmd') hotfix-defaults -Name $TestName -SettingsFile (Join-Path $fixture 'settings.json'))
    $exitCode = $LASTEXITCODE
    $result = ($output -join "`n") | ConvertFrom-Json
    if ($Fails) {
        Assert-HotfixTest ($exitCode -ne 0 -and -not $result.success) "Expected failure: $TestName"
    }
    else { Assert-HotfixTest ($exitCode -eq 0 -and $result.success) "Hotfix failed: $($output -join ' ')" }
    return $result
}
try {
    New-Item -ItemType Directory -Path (Join-Path $fixture 'tools'), (Join-Path $fixture 'repos\content\.workspace\defaults\HungerRedux'), (Join-Path $fixture 'production\HungerRedux') -Force | Out-Null
    foreach ($file in @('StillHunger.cmd', 'StillHunger.ps1', 'StillHunger.ContentAudit.ps1', 'StillHunger.Hotfix.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $fixture 'tools')
    }
    $project = Get-Content -LiteralPath $script:ProjectFile -Raw | ConvertFrom-Json
    $project.paths.production = Join-Path $fixture 'production'
    Write-JsonAtomic (Join-Path $fixture 'project.json') $project
    $repo = Join-Path $fixture 'repos\content'
    $source = Join-Path $repo '.workspace\defaults\HungerRedux\config.cfg'
    $text = "con_notifytime `"3`"`r`nsv_ignore_monster_fade_corpse `"0`"`r`nbind `"w`" `"+forward`"`r`n"
    [IO.File]::WriteAllText($source, $text)
    $null = Invoke-Git $repo @('init', '-b', 'master')
    $null = Invoke-Git $repo @('config', 'user.name', 'Hotfix Test')
    $null = Invoke-Git $repo @('config', 'user.email', 'hotfix-test@example.invalid')
    $null = Invoke-Git $repo @('add', '.')
    $null = Invoke-Git $repo @('commit', '-m', 'Fixture')
    [IO.File]::WriteAllText((Join-Path $repo 'untracked.txt'), 'Keep me')
    foreach ($component in @('engine', 'sdk')) {
        foreach ($relative in $project.requiredArtifacts.$component) {
            $file = Join-Path $project.paths.production $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
            [IO.File]::WriteAllText($file, 'fixture artifact')
        }
    }
    foreach ($relative in @('rt/data/scenes.json', 'rt/data/textures.json', 'HungerRedux/gameinfo.txt', 'valve/gameinfo.txt')) {
        $file = Join-Path $project.paths.production $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
        [IO.File]::WriteAllText($file, 'fixture content')
    }
    $config = Join-Path $project.paths.production 'HungerRedux\config.cfg'
    $user = Join-Path $project.paths.production 'HungerRedux\userconfig.cfg'
    [IO.File]::WriteAllText($config, $text)
    [IO.File]::WriteAllText($user, "// Keep my custom values`r`ncon_notifytime 7`r`nvolume 0.6`r`n")
    $before = Get-FileSha256 $config
    $null = Invoke-HotfixTest 'unknown' '{"sv_cheats":1}' -Fails
    $null = Invoke-HotfixTest 'invalid' '{"con_notifytime":"0; quit"}' -Fails
    $null = Invoke-HotfixTest 'fraction' '{"sv_ignore_monster_fade_corpse":0.5}' -Fails
    Assert-HotfixTest ((Get-FileSha256 $config) -eq $before) 'Rejected requests modified production.'
    $json = '{"con_notifytime":0,"sv_ignore_monster_fade_corpse":1}'
    $locked = [IO.File]::Open($user, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $null = Invoke-HotfixTest 'locked' $json -Fails }
    finally { $locked.Dispose() }
    Assert-HotfixTest ((Get-FileSha256 $config) -eq $before) 'Partial runtime write was not rolled back.'
    $result = Invoke-HotfixTest 'quiet' $json
    Assert-HotfixTest ($result.result.status -eq 'applied') 'Missing successful journal.'
    $expected = $text.Replace('con_notifytime "3"', 'con_notifytime "0"').Replace('sv_ignore_monster_fade_corpse "0"', 'sv_ignore_monster_fade_corpse "1"')
    Assert-HotfixTest ((Get-Content $config -Raw) -ceq $expected) 'Production settings or unrelated binding differ.'
    # Git may normalize line endings; compare config commands rather than source bytes.
    Assert-HotfixTest ((Get-Content $source -Raw).Replace("`r`n", "`n") -ceq $expected.Replace("`r`n", "`n")) 'Source defaults not integrated.'
    Assert-HotfixTest ((Get-Content $user -Raw) -ceq "// Keep my custom values`r`ncon_notifytime `"0`"`r`nvolume 0.6`r`n") 'User overrides or unrelated values differ.'
    Assert-HotfixTest ((Get-FileSha256 (Join-Path $result.result.archive 'HungerRedux\config.cfg')) -eq $before) 'Backup bytes differ.'
    Assert-HotfixTest (Test-Path (Join-Path $repo 'untracked.txt')) 'Untracked file lost.'
    Assert-HotfixTest (-not (Test-Path (Join-Path $fixture 'work\quiet'))) 'Completed worktree remains.'
    $repeat = Invoke-HotfixTest 'repeat' $json
    Assert-HotfixTest (@($repeat.result.files | Where-Object changed).Count -eq 0) 'Repeat was not a no-op.'
    [IO.File]::AppendAllText($source, '// dirty')
    $null = Invoke-HotfixTest 'dirty' $json -Fails
    return [ordered]@{ success = $true; checks = @('reject unknown/injected/fractional values', 'rollback on locked config and retry', 'source integration', 'production and override updates', 'preserve unrelated settings and untracked files', 'exact backup', 'worktree cleanup', 'idempotence', 'reject dirty master') }
}
finally {
    # This GUID-named fixture is created only by this test and verified inside the workspace.
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath (Assert-ProjectPath $fixture) -Recurse -Force }
}
