#Requires -Version 5.1

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('bash', 'powershell')]
    [string]$Shell,

    [Parameter(Mandatory = $true)]
    [string]$EncodedCommand,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

function ConvertTo-PlainHashtable {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $map = @{}
        foreach ($key in $Value.Keys) {
            $map[$key] = ConvertTo-PlainHashtable -Value $Value[$key]
        }
        return $map
    }

    if ($Value -is [pscustomobject]) {
        $map = @{}
        foreach ($property in $Value.PSObject.Properties) {
            $map[$property.Name] = ConvertTo-PlainHashtable -Value $property.Value
        }
        return $map
    }

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            [void]$items.Add((ConvertTo-PlainHashtable -Value $item))
        }
        return ,@($items.ToArray())
    }

    return $Value
}

function Read-MaskConfig {
    param([string]$Path)

    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Config file '$Path' is empty."
    }

    return ConvertTo-PlainHashtable -Value ($content | ConvertFrom-Json)
}

function Get-EnabledPatternsFromGroup {
    param(
        [System.Collections.IDictionary]$Config,
        [string]$GroupName
    )

    $enabledPatterns = @()
    if (-not $Config.Contains($GroupName) -or $null -eq $Config[$GroupName]) {
        return $enabledPatterns
    }

    foreach ($pattern in @($Config[$GroupName])) {
        if ($pattern -isnot [System.Collections.IDictionary]) {
            continue
        }

        if ($pattern.Contains('enabled') -and $false -eq [bool]$pattern['enabled']) {
            continue
        }

        if (-not $pattern.Contains('regex') -or [string]::IsNullOrWhiteSpace([string]$pattern['regex'])) {
            continue
        }

        $enabledPatterns += $pattern
    }

    return $enabledPatterns
}

function Get-ActivePatterns {
    param([System.Collections.IDictionary]$Config)

    $allPatterns = @()
    $allPatterns += @(Get-EnabledPatternsFromGroup -Config $Config -GroupName 'patterns')
    $allPatterns += @(Get-EnabledPatternsFromGroup -Config $Config -GroupName 'customPatterns')

    return $allPatterns
}

function Invoke-MaskText {
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

        try {
            $result = [regex]::Replace($result, [string]$pattern['regex'], $replacement)
        } catch {
        }
    }

    return $result
}

function Quote-ProcessArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    $escaped = $Value -replace '\\', '\\'
    $escaped = $escaped -replace '"', '\"'
    return '"' + $escaped + '"'
}

function Get-PowerShellExecutable {
    if (Get-Command powershell -ErrorAction SilentlyContinue) {
        return 'powershell'
    }

    return 'pwsh'
}

function Invoke-CapturedCommand {
    param(
        [string]$FileName,
        [string]$Arguments
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FileName
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdoutTask.Wait()
    $stderrTask.Wait()

    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdoutTask.Result
        Stderr = $stderrTask.Result
    }
}

$command = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedCommand))
$config = Read-MaskConfig -Path $ConfigPath
$patterns = Get-ActivePatterns -Config $config

if ($Shell -eq 'bash') {
    $result = Invoke-CapturedCommand -FileName 'bash' -Arguments ('-lc ' + (Quote-ProcessArgument -Value $command))
} else {
    $powerShellExecutable = Get-PowerShellExecutable
    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        (Quote-ProcessArgument -Value $command)
    ) -join ' '

    $result = Invoke-CapturedCommand -FileName $powerShellExecutable -Arguments $arguments
}

$maskedStdout = Invoke-MaskText -Text $result.Stdout -Patterns $patterns
$maskedStderr = Invoke-MaskText -Text $result.Stderr -Patterns $patterns

if (-not [string]::IsNullOrEmpty($maskedStdout)) {
    [Console]::Out.Write($maskedStdout)
}

if (-not [string]::IsNullOrEmpty($maskedStderr)) {
    [Console]::Error.Write($maskedStderr)
}

exit $result.ExitCode
