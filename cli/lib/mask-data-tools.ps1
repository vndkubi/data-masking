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
        $candidates += (Join-Path (Join-Path (Join-Path $WorkspaceRoot 'cli') 'hooks') 'masking-config.json')
        $candidates += (Join-Path (Join-Path $WorkspaceRoot 'cli') 'masking-config.json')
        $candidates += (Join-Path (Join-Path (Join-Path $WorkspaceRoot '.copilot') 'hooks') 'masking-config.json')
        $candidates += (Join-Path (Join-Path (Join-Path $WorkspaceRoot '.github') 'hooks') 'masking-config.json')
        $candidates += (Join-Path (Join-Path $WorkspaceRoot '.copilot') 'masking-config.json')
    }

    $candidates += (Join-Path (Join-Path (Join-Path $HOME '.copilot') 'hooks') 'masking-config.json')
    $candidates += (Join-Path (Join-Path $HOME '.copilot') 'masking-config.json')

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate -PathType Leaf)) {
            return Resolve-MaskDataFilePath -Path $candidate
        }
    }

    throw "masking-config.json was not found. Use -ConfigPath or create cli/masking-config.json, cli/hooks/masking-config.json, or .github/hooks/masking-config.json."
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

function Normalize-MaskDataHookEventName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    switch ($Name.ToLowerInvariant()) {
        'userpromptsubmit' { return 'UserPromptSubmit' }
        'userpromptsubmitted' { return 'UserPromptSubmit' }
        'pretooluse' { return 'PreToolUse' }
        'permissionrequest' { return 'PermissionRequest' }
        'posttooluse' { return 'PostToolUse' }
        'stop' { return 'Stop' }
        'agentstop' { return 'Stop' }
        'subagentstop' { return 'SubagentStop' }
        default { return $Name }
    }
}

function Get-MaskDataSupportedEnforcementActions {
    return @{
        UserPromptSubmit = @('mask', 'stop')
        PreToolUse = @('mask', 'deny')
        PermissionRequest = @('mask', 'deny', 'interrupt')
        PostToolUse = @('mask', 'block')
        Stop = @('mask', 'block')
        SubagentStop = @('mask', 'block')
    }
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

function Get-MaskDataNormalizedDigits {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    return ([regex]::Replace($Value, '\D', ''))
}

function Test-MaskDataLuhnChecksum {
    param([string]$Value)

    $digits = Get-MaskDataNormalizedDigits -Value $Value
    if ($digits.Length -lt 13 -or $digits.Length -gt 19) {
        return $false
    }

    if (($digits.ToCharArray() | Select-Object -Unique).Count -lt 2) {
        return $false
    }

    $sum = 0
    $doubleDigit = $false
    for ($i = $digits.Length - 1; $i -ge 0; $i--) {
        $n = [int]::Parse($digits[$i])
        if ($doubleDigit) {
            $n *= 2
            if ($n -gt 9) {
                $n -= 9
            }
        }
        $sum += $n
        $doubleDigit = -not $doubleDigit
    }

    return (($sum % 10) -eq 0)
}

function Test-MaskDataPatternMatchValue {
    param(
        [System.Collections.IDictionary]$Pattern,
        [string]$Value
    )

    $validator = if ($Pattern.Contains('validator')) { [string]$Pattern['validator'] } else { '' }
    switch ($validator.ToLowerInvariant()) {
        'luhn' { return (Test-MaskDataLuhnChecksum -Value $Value) }
        default { return $true }
    }
}

function Test-MaskDataPatternMatchesText {
    param(
        [System.Collections.IDictionary]$Pattern,
        [string]$Text
    )

    $regex = [regex]::new([string]$Pattern['regex'])
    $regexMatches = $regex.Matches($Text)
    foreach ($match in $regexMatches) {
        if (Test-MaskDataPatternMatchValue -Pattern $Pattern -Value $match.Value) {
            return $true
        }
    }

    return $false
}

function Invoke-MaskDataPatternText {
    param(
        [string]$Text,
        [System.Collections.IDictionary]$Pattern,
        [string]$Replacement
    )

    $validator = if ($Pattern.Contains('validator')) { [string]$Pattern['validator'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($validator)) {
        return [regex]::Replace($Text, [string]$Pattern['regex'], $Replacement)
    }

    $regex = [regex]::new([string]$Pattern['regex'])
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param([System.Text.RegularExpressions.Match]$Match)

        if (Test-MaskDataPatternMatchValue -Pattern $Pattern -Value $Match.Value) {
            return $Replacement
        }

        return $Match.Value
    }

    return $regex.Replace($Text, $evaluator)
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

        $result = Invoke-MaskDataPatternText -Text $result -Pattern $pattern -Replacement $replacement
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
            if (Test-MaskDataPatternMatchesText -Pattern $pattern -Text $Text) {
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

    foreach ($fieldName in @('externalToolsRegex', 'sensitiveFilenameRegex', 'denyPathRegex', 'denyShellCommandRegex')) {
        if ($config.Contains($fieldName) -and -not [string]::IsNullOrWhiteSpace([string]$config[$fieldName])) {
            try {
                [void][regex]::new([string]$config[$fieldName])
            } catch {
                [void]$errors.Add("Invalid regex in '$fieldName': $($_.Exception.Message)")
            }
        }
    }

    if ($config.Contains('sensitiveFilenameValidator') -and -not [string]::IsNullOrWhiteSpace([string]$config['sensitiveFilenameValidator'])) {
        $sensitiveFilenameValidator = [string]$config['sensitiveFilenameValidator']
        if ($sensitiveFilenameValidator -notin @('luhn')) {
            [void]$errors.Add("sensitiveFilenameValidator '$sensitiveFilenameValidator' is unsupported. Allowed: luhn")
        }
    }

    if ($config.Contains('maskedPathMode') -and -not [string]::IsNullOrWhiteSpace([string]$config['maskedPathMode'])) {
        $maskedPathMode = [string]$config['maskedPathMode']
        if ($maskedPathMode -notin @('workspaceMirror', 'tempHash')) {
            [void]$errors.Add("maskedPathMode '$maskedPathMode' is unsupported. Allowed: workspaceMirror, tempHash")
        }
    }

    if ($config.Contains('userPromptSubmitUnsupportedMode') -and -not [string]::IsNullOrWhiteSpace([string]$config['userPromptSubmitUnsupportedMode'])) {
        $userPromptSubmitUnsupportedMode = [string]$config['userPromptSubmitUnsupportedMode']
        if ($userPromptSubmitUnsupportedMode -notin @('continue', 'block')) {
            [void]$errors.Add("userPromptSubmitUnsupportedMode '$userPromptSubmitUnsupportedMode' is unsupported. Allowed: continue, block")
        }
    }

    if ($config.Contains('blockedPaths') -and $null -ne $config['blockedPaths']) {
        foreach ($blockedPath in @($config['blockedPaths'])) {
            if ([string]::IsNullOrWhiteSpace([string]$blockedPath)) {
                [void]$errors.Add("blockedPaths entries must be non-empty strings.")
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

        if ($entry.Pattern.Contains('validator') -and -not [string]::IsNullOrWhiteSpace([string]$entry.Pattern['validator'])) {
            $validator = [string]$entry.Pattern['validator']
            if ($validator -notin @('luhn')) {
                [void]$errors.Add("$displayName validator '$validator' is unsupported. Allowed: luhn")
            }
        }

        if ($entry.Pattern.Contains('enforcement') -and $null -ne $entry.Pattern['enforcement']) {
            $supportedEnforcement = Get-MaskDataSupportedEnforcementActions
            $enforcement = $entry.Pattern['enforcement']

            if ($enforcement -isnot [System.Collections.IDictionary]) {
                [void]$errors.Add("$displayName enforcement must be a JSON object.")
            } else {
                foreach ($eventKey in $enforcement.Keys) {
                    $normalizedEvent = Normalize-MaskDataHookEventName -Name ([string]$eventKey)
                    if (-not $supportedEnforcement.Contains($normalizedEvent)) {
                        [void]$errors.Add("$displayName enforcement uses unsupported event '$eventKey'.")
                        continue
                    }

                    $action = [string]$enforcement[$eventKey]
                    if ([string]::IsNullOrWhiteSpace($action)) {
                        [void]$errors.Add("$displayName enforcement for '$normalizedEvent' must be a non-empty string.")
                        continue
                    }

                    if ($action -notin $supportedEnforcement[$normalizedEvent]) {
                        $allowedActions = ($supportedEnforcement[$normalizedEvent] -join ', ')
                        [void]$errors.Add("$displayName enforcement action '$action' is invalid for '$normalizedEvent'. Allowed: $allowedActions")
                    }
                }
            }
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
