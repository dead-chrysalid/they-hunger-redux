# Deliberately limited to numeric profile defaults. Binary/content hotfixes use finish.
function Update-HotfixConfig {
    param([string]$Text, $Settings, [switch]$AppendMissing)
    foreach ($setting in $Settings.PSObject.Properties) {
        $pattern = '(?im)^([ \t]*' + [regex]::Escape($setting.Name) + '[ \t]+)[^\r\n]*'
        $replacement = '${1}"' + [string]$setting.Value + '"'
        if ([regex]::IsMatch($Text, $pattern)) {
            $Text = [regex]::Replace($Text, $pattern, $replacement)
        }
        elseif ($AppendMissing) {
            $Text = $Text.TrimEnd("`r", "`n") + "`r`n$($setting.Name) `"$($setting.Value)`"`r`n"
        }
    }
    return $Text
}

function Invoke-HotfixDefaults {
    Require-FeatureName
    if (-not $SettingsFile) { throw '-SettingsFile is required for hotfix-defaults.' }
    Enter-ProjectLock
    $settings = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
    $properties = @($settings.PSObject.Properties)
    if ($properties.Count -eq 0) { throw 'Settings must be a nonempty JSON object.' }
    foreach ($setting in $properties) {
        $rule = $script:Project.hotfixPolicy.numericDefaults.PSObject.Properties[$setting.Name]
        if (-not $rule -or [string]$setting.Value -notmatch '^\d+(\.\d+)?$') {
            throw "Unsupported numeric default: $($setting.Name)"
        }
        $number = [double]::Parse([string]$setting.Value, [Globalization.CultureInfo]::InvariantCulture)
        if ($number -lt $rule.Value.min -or $number -gt $rule.Value.max) {
            throw "Default out of range: $($setting.Name)"
        }
        if ($rule.Value.PSObject.Properties['integer'] -and $rule.Value.integer -and
            $number -ne [math]::Floor($number)) { throw "Default must be an integer: $($setting.Name)" }
    }
    $production = Resolve-ProjectPath $script:Project.paths.production
    Assert-RuntimeIdle $production
    $runtime = Test-Runtime $production
    if (-not $runtime.valid) { throw 'Hotfix requires an existing complete production runtime.' }
    $repo = Get-RepoPath 'content'
    $master = [string]$script:Project.branches.content
    if ((Invoke-Git $repo @('branch', '--show-current')) -ne $master -or
        (Invoke-Git $repo @('diff', '--name-only')) -or
        (Invoke-Git $repo @('diff', '--cached', '--name-only'))) {
        throw 'Content master must have no tracked changes. Untracked files are preserved.'
    }
    $root = Get-FeatureRoot $Name
    if (Test-Path -LiteralPath $root) { throw "Work directory already exists: $root" }
    $branch = [string]$script:Project.branches.featurePrefix + $Name
    $sourceFile = Join-Path (Resolve-ProjectPath $script:Project.initialDefaults.game) 'config.cfg'
    if (-not $sourceFile.StartsWith($repo.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Initial game defaults must belong to the content repository.'
    }
    $relative = $sourceFile.Substring($repo.TrimEnd('\').Length + 1).Replace('\', '/')
    $null = Invoke-Git $repo @('ls-files', '--error-unmatch', '--', $relative)
    $sourceBefore = Get-Content -LiteralPath $sourceFile -Raw
    foreach ($setting in $properties) {
        if ($sourceBefore -notmatch ('(?im)^\s*' + [regex]::Escape($setting.Name) + '\s+')) {
            throw "Default is absent from the source template: $($setting.Name)"
        }
    }
    $archive = Assert-ProjectPath (Join-Path (Resolve-ProjectPath $script:Project.paths.archives) (
        "hotfix-$Name-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    ))
    New-Item -ItemType Directory -Path $archive | Out-Null
    $updates = [Collections.Generic.List[object]]::new()
    $configRelative = "$($script:Project.gameToken)/config.cfg"
    foreach ($path in @($configRelative, "$($script:Project.gameToken)/userconfig.cfg")) {
        $file = Join-Path $production $path
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            if ($path -eq $configRelative) { throw 'Production config.cfg is missing.' }
            continue
        }
        $before = Get-Content -LiteralPath $file -Raw
        $after = Update-HotfixConfig $before $settings -AppendMissing:($path -eq $configRelative)
        $backup = Join-Path $archive $path
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
        Copy-Item -LiteralPath $file -Destination $backup
        $updates.Add([pscustomobject]@{ path = $path; file = $file; backup = $backup;
            beforeSha256 = Get-FileSha256 $file; text = $after; changed = ($before -cne $after); applied = $false })
    }
    Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $archive 'source-config.cfg')
    $record = [ordered]@{ name = $Name; kind = 'numeric-defaults'; status = 'prepared';
        createdUtc = [DateTime]::UtcNow.ToString('o'); production = $production;
        settings = $settings; sourcePath = $relative; sourceBefore = Invoke-Git $repo @('rev-parse', 'HEAD');
        sourceAfter = $null; files = @(); archive = $archive }
    $journal = Join-Path $archive 'hotfix.json'
    Write-JsonAtomic $journal $record
    $worktree = Join-Path $root 'runtime'
    $added = $false
    try {
        New-Item -ItemType Directory -Path $root | Out-Null
        $null = Invoke-Git $repo @('worktree', 'add', '-b', $branch, $worktree, $master)
        $added = $true
        $target = Join-Path $worktree $relative
        $after = Update-HotfixConfig $sourceBefore $settings
        if ($after -cne $sourceBefore) {
            [IO.File]::WriteAllText($target, $after, [Text.UTF8Encoding]::new($false))
            $null = Invoke-Git $worktree @('add', '--', $relative)
            $null = Invoke-Git $worktree @('commit', '-m', "Hotfix defaults: $Name")
            $null = Invoke-Git $repo @('merge', '--ff-only', $branch)
        }
        $record.sourceAfter = Invoke-Git $repo @('rev-parse', 'HEAD')
        $record.status = 'source-integrated'
        Write-JsonAtomic $journal $record
        Assert-RuntimeIdle $production
        foreach ($update in $updates) {
            if ((Get-FileSha256 $update.file) -cne $update.beforeSha256) {
                throw "Config changed during hotfix: $($update.path)"
            }
        }
        $record.status = 'applying'
        Write-JsonAtomic $journal $record
        foreach ($update in $updates) {
            if (-not $update.changed) { continue }
            $temporary = "$($update.file).hotfix-$PID"
            try {
                [IO.File]::WriteAllText($temporary, $update.text, [Text.UTF8Encoding]::new($false))
                [IO.File]::Replace($temporary, $update.file, "$temporary.before")
                $update.applied = $true
            }
            finally {
                foreach ($leftover in @($temporary, "$temporary.before")) {
                    if (Test-Path -LiteralPath $leftover) { Remove-Item -LiteralPath $leftover }
                }
            }
        }
        $record.files = @($updates | ForEach-Object { [ordered]@{ path = $_.path;
            changed = $_.changed; beforeSha256 = $_.beforeSha256; afterSha256 = Get-FileSha256 $_.file } })
        foreach ($update in $updates) {
            if ((Get-Content -LiteralPath $update.file -Raw) -cne $update.text) {
                throw "Config verification failed: $($update.path)"
            }
        }
        $record.status = 'applied'
        Write-JsonAtomic $journal $record
        Write-JsonAtomic (Join-Path $script:ProjectRoot '.state\hotfix-defaults.json') $record
        return $record
    }
    catch {
        # Source commits remain intentional and retryable; only our runtime writes roll back.
        if ($record.status -eq 'applying') {
            foreach ($update in $updates) {
                if ($update.applied) { Copy-Item -LiteralPath $update.backup -Destination $update.file -Force }
            }
        }
        $record.status = 'failed'
        $record['error'] = $_.Exception.Message
        Write-JsonAtomic $journal $record
        throw
    }
    finally {
        if ($added) {
            $null = Invoke-Git $repo @('worktree', 'remove', $worktree)
            $null = Invoke-Git $repo @('branch', '-d', $branch)
        }
        if ((Test-Path -LiteralPath $root) -and @(Get-ChildItem -LiteralPath $root -Force).Count -eq 0) {
            Remove-Item -LiteralPath $root
        }
    }
}
