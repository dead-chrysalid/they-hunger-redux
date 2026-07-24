Set-StrictMode -Version Latest

function Test-StillHungerPolicyPattern {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)]$Patterns
    )

    $relative = $RelativePath.Replace('\', '/')
    foreach ($pattern in $Patterns) {
        if ([System.Management.Automation.WildcardPattern]::new(
                [string]$pattern,
                [System.Management.Automation.WildcardOptions]::IgnoreCase
            ).IsMatch($relative)) {
            return $true
        }
    }
    return $false
}

function Get-StillHungerRelativeFiles {
    param([Parameter(Mandatory)][string]$Root)

    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return @(
        Get-ChildItem -LiteralPath $rootPath -Recurse -Force -File |
            ForEach-Object {
                [pscustomobject]@{
                    file = $_
                    relative = $_.FullName.Substring($rootPath.Length + 1).Replace('\', '/')
                }
            }
    )
}

function Add-StillHungerHudAssets {
    param(
        [Parameter(Mandatory)][AllowNull()]$Node,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Prefix,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Assets
    )

    if ($null -eq $Node -or $Node -isnot [pscustomobject]) { return }

    foreach ($property in $Node.PSObject.Properties) {
        $id = if ([string]::IsNullOrEmpty($Prefix)) {
            $property.Name
        }
        else {
            "$Prefix/$($property.Name)"
        }
        $value = $property.Value
        if ($null -ne $value -and $value -is [pscustomobject] -and $value.PSObject.Properties['path']) {
            $Assets.Add([pscustomobject]@{
                id = $id
                path = [string]$value.path
            })
        }
        elseif ($null -ne $value -and $value -is [pscustomobject]) {
            Add-StillHungerHudAssets $value $id $Assets
        }
    }
}

function Add-StillHungerJsonUris {
    param(
        [AllowNull()]$Node,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[string]]$Uris
    )

    if ($null -eq $Node) { return }

    if ($Node -is [pscustomobject]) {
        foreach ($property in $Node.PSObject.Properties) {
            if ($property.Name -eq 'uri' -and $property.Value -is [string]) {
                $Uris.Add([string]$property.Value)
            }
            else {
                Add-StillHungerJsonUris $property.Value $Uris
            }
        }
        return
    }

    if ($Node -is [Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($item in $Node) {
            Add-StillHungerJsonUris $item $Uris
        }
    }
}

function Test-StillHungerContent {
    param(
        [Parameter(Mandatory)][string]$Runtime,
        [Parameter(Mandatory)]$Project,
        [switch]$Payload,
        [switch]$AllowGenerated
    )

    $runtimePath = [IO.Path]::GetFullPath($Runtime).TrimEnd('\')
    $errors = [Collections.Generic.List[string]]::new()
    $warnings = [Collections.Generic.List[string]]::new()
    $files = @(Get-StillHungerRelativeFiles $runtimePath)
    $deployable = @(
        foreach ($entry in $files) {
            $excluded = Test-StillHungerPolicyPattern $entry.relative $Project.releaseExclusions
            if ($Payload -and $excluded -and -not $AllowGenerated) {
                $errors.Add("excluded-file-shipped:$($entry.relative)")
            }
            if (-not $excluded) { $entry }
        }
    )

    foreach ($entry in $deployable) {
        if (Test-StillHungerPolicyPattern $entry.relative $Project.releasePolicy.forbiddenRuntimePatterns) {
            $errors.Add("forbidden-file:$($entry.relative)")
        }
    }

    $mapRoot = Join-Path $runtimePath "$($Project.gameToken)\maps"
    $actualMaps = @(
        Get-ChildItem -LiteralPath $mapRoot -File -Filter '*.bsp' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.BaseName.ToLowerInvariant() } |
            Sort-Object
    )
    $expectedMaps = @(
        $Project.releasePolicy.campaignMaps |
            ForEach-Object { ([string]$_).ToLowerInvariant() } |
            Sort-Object
    )
    if (($actualMaps -join "`n") -cne ($expectedMaps -join "`n")) {
        $errors.Add("map-set:expected=$($expectedMaps -join ',');actual=$($actualMaps -join ',')")
    }

    $sceneNames = @($expectedMaps | Where-Object { $_ -ne 'menu' })
    $actualScenes = @(
        Get-ChildItem -LiteralPath (Join-Path $runtimePath 'rt\scenes') -Recurse -File -Filter '*.gltf' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.BaseName.ToLowerInvariant() } |
            Sort-Object
    )
    if (($actualScenes -join "`n") -cne (($sceneNames | Sort-Object) -join "`n")) {
        $errors.Add("scene-set:expected=$($sceneNames.Count);actual=$($actualScenes.Count)")
    }

    $missingUris = [Collections.Generic.List[string]]::new()
    foreach ($sceneName in $sceneNames) {
        $gltf = Join-Path $runtimePath "rt\scenes\$sceneName\$sceneName.gltf"
        if (-not (Test-Path -LiteralPath $gltf -PathType Leaf)) {
            $errors.Add("missing-scene:$sceneName")
            continue
        }
        try {
            $document = Get-Content -LiteralPath $gltf -Raw | ConvertFrom-Json
            $uris = [Collections.Generic.List[string]]::new()
            Add-StillHungerJsonUris $document $uris
            foreach ($uri in $uris) {
                if ($uri.StartsWith('data:', [StringComparison]::OrdinalIgnoreCase)) { continue }
                $decoded = [Uri]::UnescapeDataString($uri)
                $target = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $gltf) ($decoded -replace '/', '\')))
                if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                    $missingUris.Add("${sceneName}:$uri")
                }
            }
        }
        catch {
            $errors.Add("invalid-gltf:${sceneName}:$($_.Exception.Message)")
        }
    }
    foreach ($missing in $missingUris) {
        $errors.Add("missing-gltf-uri:$missing")
    }

    $textureConfig = Join-Path $runtimePath 'rt\data\textures.json'
    try {
        $textures = Get-Content -LiteralPath $textureConfig -Raw | ConvertFrom-Json
        if ($null -eq $textures.array -or @($textures.array).Count -eq 0) {
            $errors.Add('textures-json:empty')
        }
    }
    catch {
        $errors.Add("textures-json:invalid:$($_.Exception.Message)")
    }

    $hudFile = Join-Path $runtimePath "$($Project.gameToken)\sprites\hud.json"
    try {
        $hud = Get-Content -LiteralPath $hudFile -Raw | ConvertFrom-Json
        foreach ($required in $Project.releasePolicy.requiredHudEntries) {
            if (-not $hud.PSObject.Properties[[string]$required]) {
                $errors.Add("hud-required-entry:$required")
            }
        }

        if (-not $hud.PSObject.Properties['weapons']) {
            $errors.Add('hud-weapons:missing')
        }
        else {
            foreach ($weapon in $hud.weapons.PSObject.Properties) {
                foreach ($requiredSlot in @('icon', 'shadow')) {
                    if (-not $weapon.Value.PSObject.Properties[$requiredSlot]) {
                        $errors.Add("hud-weapon-slot:$($weapon.Name)/$requiredSlot")
                    }
                }
            }
        }

        $assets = [Collections.Generic.List[object]]::new()
        Add-StillHungerHudAssets $hud '' $assets
        foreach ($asset in $assets) {
            $assetPath = Join-Path (Join-Path $runtimePath $Project.gameToken) ($asset.path -replace '/', '\')
            if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
                $errors.Add("hud-path:$($asset.id):$($asset.path)")
            }
        }
    }
    catch {
        $errors.Add("hud-json:invalid:$($_.Exception.Message)")
    }

    $gameRoot = Join-Path $runtimePath $Project.gameToken
    $valveRoot = Join-Path $runtimePath 'valve'
    if (Test-Path -LiteralPath $valveRoot -PathType Container) {
        foreach ($gameFile in Get-ChildItem -LiteralPath $gameRoot -Recurse -File -ErrorAction SilentlyContinue) {
            $relative = $gameFile.FullName.Substring($gameRoot.Length + 1)
            $fallback = Join-Path $valveRoot $relative
            if (-not (Test-Path -LiteralPath $fallback -PathType Leaf)) { continue }
            $fallbackFile = Get-Item -LiteralPath $fallback
            if ($gameFile.Length -ne $fallbackFile.Length) { continue }
            $gameHash = (Get-FileHash -LiteralPath $gameFile.FullName -Algorithm SHA256).Hash
            $fallbackHash = (Get-FileHash -LiteralPath $fallback -Algorithm SHA256).Hash
            if ($gameHash -ceq $fallbackHash) {
                $errors.Add("duplicate-valve-override:$($relative.Replace('\', '/'))")
            }
        }
    }

    $result = [ordered]@{
        success = $errors.Count -eq 0
        runtime = $runtimePath
        payload = [bool]$Payload
        files = $deployable.Count
        bytes = ($deployable | ForEach-Object { $_.file.Length } | Measure-Object -Sum).Sum
        maps = $actualMaps.Count
        scenes = $actualScenes.Count
        errors = @($errors)
        warnings = @($warnings)
        auditedUtc = [DateTime]::UtcNow.ToString('o')
    }

    if (-not $result.success) {
        throw "Content audit failed: $($errors -join '; ')"
    }
    return $result
}
