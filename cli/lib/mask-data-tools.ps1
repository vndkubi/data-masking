#Requires -Version 5.1

function Resolve-MaskDataFilePath {
    param([string]$Path)

    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function ConvertTo-MaskDataHashtable {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $map = @{}
        foreach ($key in $Value.Keys) {
            $map[$key] = ConvertTo-MaskDataHashtable -Value $Value[$key]
        }
        return $map
    }

    if ($Value -is [pscustomobject]) {
        $map = @{}
        foreach ($property in $Value.PSObject.Properties) {
            $map[$property.Name] = ConvertTo-MaskDataHashtable -Value $property.Value
        }
        return $map
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            [void]$items.Add((ConvertTo-MaskDataHashtable -Value $item))
        }
        return ,@($items.ToArray())
    }

    return $Value
}

function Resolve-DefaultMaskDataConfigPath {
    param(
        [string]$ConfigPath,
        [string]$WorkspaceRoot = (Get-Location).Path
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        return Resolve-MaskDataFilePath -Path $ConfigPath
    }

    $candidates = @()
    if ($env:MASK_DATA_CONFIG) {
        $candidates += $env:MASK_DATA_CONFIG
    }

    if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        $candidates += (Join-Path (Join-Path $WorkspaceRoot 'cli') 'masking-config.json')
        $candidates += (Join-Path (Join-Path (Join-Path $WorkspaceRoot '.github') 'hooks') 'masking-config.json')
        $candidates += (Join-Path (Join-Path $WorkspaceRoot '.copilot') 'masking-config.json')
    }

    $candidates += (Join-Path (Join-Path $HOME '.copilot') 'masking-config.json')

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate -PathType Leaf)) {
            return Resolve-MaskDataFilePath -Path $candidate
        }
    }

    throw "masking-config.json was not found. Use -ConfigPath or create cli/masking-config.json."
}

function Read-MaskDataConfig {
    param([string]$ConfigPath)

    $resolvedPath = Resolve-MaskDataFilePath -Path $ConfigPath
    $content = Get-Content -Path $resolvedPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Config file '$resolvedPath' is empty."
    }

    $config = ConvertTo-MaskDataHashtable -Value ($content | ConvertFrom-Json)
    if ($config -isnot [System.Collections.IDictionary]) {
        throw "Config file '$resolvedPath' must contain a JSON object."
    }

    return $config
}

function Get-MaskDataPatternEntries {
    param([System.Collections.IDictionary]$Config)

    $entries = New-Object System.Collections.ArrayList

    foreach ($groupName in @('patterns', 'customPatterns')) {
        if (-not $Config.Contains($groupName) -or $null -eq $Config[$groupName]) {
            continue
        }

        $index = 0
        foreach ($pattern in @($Config[$groupName])) {
            [void]$entries.Add([pscustomobject]@{
                GroupName = $groupName
                Index = $index
                Pattern = $pattern
            })
            $index++
        }
    }

    return @($entries.ToArray())
}

function Get-ActiveMaskPatterns {
    param([System.Collections.IDictionary]$Config)

    $activePatterns = New-Object System.Collections.ArrayList
    $entries = @(Get-MaskDataPatternEntries -Config $Config)
    foreach ($entry in $entries) {
        if ($entry.Pattern -isnot [System.Collections.IDictionary]) {
            continue
        }

        if ($entry.Pattern.Contains('enabled') -and $false -eq [bool]$entry.Pattern['enabled']) {
            continue
        }

        if (-not $entry.Pattern.Contains('regex') -or [string]::IsNullOrWhiteSpace([string]$entry.Pattern['regex'])) {
            continue
        }

        [void]$activePatterns.Add($entry.Pattern)
    }

    Write-Output -NoEnumerate ([object[]]$activePatterns.ToArray())
    return
}

function Invoke-MaskDataText {
    param(
        [string]$Text,
        [System.Collections.IEnumerable]$Patterns
    )

    $result = $Text
    foreach ($pattern in $Patterns) {
        $replacement = if ($pattern.Contains('replacement')) {
            [string]$pattern['replacement']
        } elseif ($pattern.Contains('name')) {
            [string]$pattern['name']
        } else {
            $null
        }

        if ([string]::IsNullOrWhiteSpace($replacement)) {
            continue
        }

        $result = [regex]::Replace($result, [string]$pattern['regex'], $replacement)
    }

    return $result
}

function Get-MaskDataMatchedPatterns {
    param(
        [string]$Text,
        [System.Collections.IEnumerable]$Patterns
    )

    $matches = New-Object System.Collections.ArrayList
    foreach ($pattern in $Patterns) {
        try {
            if ([regex]::IsMatch($Text, [string]$pattern['regex'])) {
                $name = if ($pattern.Contains('name') -and -not [string]::IsNullOrWhiteSpace([string]$pattern['name'])) {
                    [string]$pattern['name']
                } else {
                    [string]$pattern['regex']
                }
                [void]$matches.Add($name)
            }
        } catch {
        }
    }

    Write-Output -NoEnumerate ([object[]]$matches.ToArray())
    return
}

function Test-MaskDataConfig {
    param([string]$ConfigPath)

    $errors = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $resolvedPath = $null
    $config = $null

    try {
        $resolvedPath = Resolve-MaskDataFilePath -Path $ConfigPath
        $config = Read-MaskDataConfig -ConfigPath $resolvedPath
    } catch {
        [void]$errors.Add($_.Exception.Message)
        return [pscustomobject]@{
            ConfigPath = $ConfigPath
            Config = $null
            Errors = @($errors.ToArray())
            Warnings = @($warnings.ToArray())
            TotalPatterns = 0
            ActivePatterns = 0
        }
    }

    foreach ($fieldName in @('externalToolsRegex', 'sensitiveFilenameRegex')) {
        if ($config.Contains($fieldName) -and -not [string]::IsNullOrWhiteSpace([string]$config[$fieldName])) {
            try {
                [void][regex]::new([string]$config[$fieldName])
            } catch {
                [void]$errors.Add("Invalid regex in '$fieldName': $($_.Exception.Message)")
            }
        }
    }

    $entries = Get-MaskDataPatternEntries -Config $config
    if ($entries.Count -eq 0) {
        [void]$errors.Add("Config '$resolvedPath' must define at least one item in 'patterns' or 'customPatterns'.")
    }

    $enabledEntries = New-Object System.Collections.ArrayList
    foreach ($entry in $entries) {
        $label = "$($entry.GroupName)[$($entry.Index)]"

        if ($entry.Pattern -isnot [System.Collections.IDictionary]) {
            [void]$errors.Add("$label must be a JSON object.")
            continue
        }

        $name = if ($entry.Pattern.Contains('name')) { [string]$entry.Pattern['name'] } else { '' }
        $regex = if ($entry.Pattern.Contains('regex')) { [string]$entry.Pattern['regex'] } else { '' }
        $replacement = if ($entry.Pattern.Contains('replacement')) { [string]$entry.Pattern['replacement'] } else { $name }
        $enabled = -not ($entry.Pattern.Contains('enabled') -and $false -eq [bool]$entry.Pattern['enabled'])
        $displayName = if ([string]::IsNullOrWhiteSpace($name)) { $label } else { $name }

        if ([string]::IsNullOrWhiteSpace($name)) {
            [void]$warnings.Add("$label has no 'name'.")
        }

        if ([string]::IsNullOrWhiteSpace($regex)) {
            [void]$errors.Add("$displayName is missing 'regex'.")
            continue
        }

        try {
            [void][regex]::new($regex)
        } catch {
            [void]$errors.Add("$displayName has invalid regex: $($_.Exception.Message)")
        }

        if ([string]::IsNullOrWhiteSpace($replacement)) {
            [void]$errors.Add("$displayName must define 'replacement' or 'name'.")
        }

        if ($enabled) {
            [void]$enabledEntries.Add([pscustomobject]@{
                Name = $displayName
                Replacement = $replacement
            })
        }
    }

    $duplicateNames = $entries |
        Where-Object { $_.Pattern -is [System.Collections.IDictionary] -and -not [string]::IsNullOrWhiteSpace([string]$_.Pattern['name']) } |
        Group-Object { [string]$_.Pattern['name'] } |
        Where-Object { $_.Count -gt 1 }

    foreach ($group in $duplicateNames) {
        [void]$warnings.Add("Duplicate pattern name: '$($group.Name)'.")
    }

    $duplicateReplacements = $enabledEntries |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Replacement) } |
        Group-Object Replacement |
        Where-Object { $_.Count -gt 1 }

    foreach ($group in $duplicateReplacements) {
        $names = ($group.Group | Select-Object -ExpandProperty Name) -join ', '
        [void]$warnings.Add("Duplicate replacement '$($group.Name)' used by: $names")
    }

    return [pscustomobject]@{
        ConfigPath = $resolvedPath
        Config = $config
        Errors = @($errors.ToArray())
        Warnings = @($warnings.ToArray())
        TotalPatterns = $entries.Count
        ActivePatterns = (Get-ActiveMaskPatterns -Config $config).Count
    }
}
