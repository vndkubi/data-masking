# =============================================================
# test-masking.ps1
# Cross-platform test runner for masking-config.json patterns
# Works on: Windows PowerShell 5.1+, PowerShell Core 7+ (Win/Mac/Linux)
# No external dependencies required (pure PowerShell regex testing)
#
# Usage:
#   .\tests\test-masking.ps1
#   .\tests\test-masking.ps1 -FixturePath .\tests\fixtures\test-email-addresses.json
# =============================================================
param(
    [string]$FixturePath = "",
    [string]$ProjectRoot = ""
)

# ------------------------------------------------------------------
# Setup
# ------------------------------------------------------------------
$ErrorActionPreference = "Continue"

if (-not $ProjectRoot) {
    $ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if (-not $ProjectRoot) {
        $ProjectRoot = (Get-Location).Path
    }
}

# Try resolving from script location
$ScriptOwnDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptOwnDir

$ConfigPath = Join-Path $ProjectRoot ".github\hooks\masking-config.json"
$FixtureDir = Join-Path $ProjectRoot "tests\fixtures"

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config not found: $ConfigPath"
    exit 1
}

# ------------------------------------------------------------------
# Load config patterns
# ------------------------------------------------------------------
$rawJson = (Get-Content $ConfigPath -Raw -Encoding UTF8) -replace '(?m)^\s*//.*$', ''
$config = $rawJson | ConvertFrom-Json

function Invoke-Mask {
    param([string]$Content)

    $result = $Content
    foreach ($pattern in $config.patterns) {
        # Skip disabled patterns
        if ($null -ne $pattern.enabled -and $pattern.enabled -eq $false) {
            continue
        }

        $regex = $pattern.regex
        if (-not $regex) { continue }

        $replacement = $pattern.replacement
        if (-not $replacement) { $replacement = $pattern.name }
        if (-not $replacement) { continue }

        # PowerShell uses .NET regex which supports (?i) natively
        try {
            $result = [regex]::Replace($result, $regex, $replacement)
        } catch {
            Write-Warning "Regex error in pattern '$($pattern.name)': $_"
        }
    }

    # Also apply customPatterns if present
    if ($config.customPatterns) {
        foreach ($cp in $config.customPatterns) {
            $regex = $cp.regex
            $replacement = if ($cp.replacement) { $cp.replacement } else { $cp.name }
            if ($regex -and $replacement) {
                try {
                    $result = [regex]::Replace($result, $regex, $replacement)
                } catch {
                    Write-Warning "Regex error in custom pattern: $_"
                }
            }
        }
    }

    return $result
}

function Test-HasSensitive {
    param([string]$Content)
    foreach ($pattern in $config.patterns) {
        if ($null -ne $pattern.enabled -and $pattern.enabled -eq $false) { continue }
        $regex = $pattern.regex
        if ($regex -and [regex]::IsMatch($Content, $regex)) {
            return $true
        }
    }
    return $false
}

# ------------------------------------------------------------------
# Test engine
# ------------------------------------------------------------------
$Total   = 0
$Passed  = 0
$Failed  = 0
$Skipped = 0

function Run-TestCase {
    param(
        [string]$TestId,
        [string]$TestName,
        [string]$TestInput,
        [string]$ExpectMasked,
        [string]$ExpectOutput,
        [string]$ExpectContains,
        $ExpectAlsoContains,
        [string]$Note
    )

    $script:Total++
    $result = Invoke-Mask -Content $TestInput
    $wasMasked = ($result -ne $TestInput)
    $status = "PASS"
    $detail = ""

    if ($ExpectMasked -eq "true") {
        if (-not $wasMasked) {
            $status = "FAIL"
            $detail = "Expected masking but content was unchanged"
        } elseif ($ExpectOutput -and $result -ne $ExpectOutput) {
            $status = "FAIL"
            $detail = "Expected: '$ExpectOutput', Got: '$result'"
        } elseif ($ExpectContains -and $result -notmatch [regex]::Escape($ExpectContains)) {
            $status = "FAIL"
            $detail = "Expected to contain '$ExpectContains', Got: '$result'"
        }

        # Check also_contains
        if ($status -eq "PASS" -and $ExpectAlsoContains) {
            foreach ($also in $ExpectAlsoContains) {
                if ($result -notmatch [regex]::Escape($also)) {
                    $status = "FAIL"
                    $detail = "Expected to also contain '$also', Got: '$result'"
                    break
                }
            }
        }
    } elseif ($ExpectMasked -eq "false") {
        if ($wasMasked) {
            $status = "FAIL"
            $detail = "Expected NO masking but got: '$result'"
        }
    } else {
        # Unknown/info case
        $status = "INFO"
        if ($wasMasked) {
            $detail = "(info) Masked by other pattern: '$result'"
        } else {
            $detail = "(info) No masking occurred"
        }
        $script:Skipped++
    }

    switch ($status) {
        "PASS" {
            Write-Host "  " -NoNewline
            Write-Host "PASS" -ForegroundColor Green -NoNewline
            Write-Host " [$TestId] $TestName"
            $script:Passed++
        }
        "FAIL" {
            Write-Host "  " -NoNewline
            Write-Host "FAIL" -ForegroundColor Red -NoNewline
            Write-Host " [$TestId] $TestName"
            Write-Host "         $detail" -ForegroundColor Red
            if ($Note) { Write-Host "         Note: $Note" -ForegroundColor DarkGray }
            $script:Failed++
        }
        "INFO" {
            Write-Host "  " -NoNewline
            Write-Host "INFO" -ForegroundColor Yellow -NoNewline
            Write-Host " [$TestId] $TestName"
            Write-Host "         $detail" -ForegroundColor DarkGray
        }
    }
}

function Run-FixtureFile {
    param([string]$FilePath)

    $fixture = Get-Content $FilePath -Raw | ConvertFrom-Json
    $filename = Split-Path -Leaf $FilePath

    Write-Host ""
    Write-Host "--- $filename ---" -ForegroundColor Cyan
    if ($fixture._description) {
        Write-Host "  $($fixture._description)" -ForegroundColor DarkGray
    }

    foreach ($case in $fixture.cases) {
        $expectMasked = if ($null -ne $case.expect_masked) { $case.expect_masked.ToString().ToLower() } else { "unknown" }

        $tid   = if ($case.id)    { $case.id }    else { "?" }
        $tname = if ($case.name)  { $case.name }  else { "Unnamed" }
        $tinp  = if ($null -ne $case.input) { $case.input } else { "" }
        $tout  = if ($case.expect_output)   { $case.expect_output }   else { "" }
        $tcon  = if ($case.expect_contains) { $case.expect_contains } else { "" }
        $tnote = if ($case.note)            { $case.note }            else { "" }

        Run-TestCase `
            -TestId            $tid `
            -TestName          $tname `
            -TestInput         $tinp `
            -ExpectMasked      $expectMasked `
            -ExpectOutput      $tout `
            -ExpectContains    $tcon `
            -ExpectAlsoContains ($case.expect_also_contains) `
            -Note              $tnote
    }
}

# ------------------------------------------------------------------
# Detect platform
# ------------------------------------------------------------------
$platform = if ($IsLinux) { "Linux" }
  elseif ($IsMacOS) { "macOS" }
  elseif ($env:WSL_DISTRO_NAME) { "WSL" }
  else { "Windows" }

$psVer = "$($PSVersionTable.PSVersion)"

# ------------------------------------------------------------------
# Main
# ------------------------------------------------------------------
Write-Host "`n=============================================" -ForegroundColor White
Write-Host "  Sensitive Data Masking - Test Runner (PS)" -ForegroundColor White
Write-Host "=============================================" -ForegroundColor White
Write-Host "  Platform   : $platform" -ForegroundColor Cyan
Write-Host "  PowerShell : $psVer" -ForegroundColor Cyan
Write-Host "  Config     : $ConfigPath" -ForegroundColor DarkGray

# Determine fixtures
if ($FixturePath) {
    $fixtures = @($FixturePath)
} else {
    $fixtures = @(Get-ChildItem -Path $FixtureDir -Filter "test-*.json" -File | Select-Object -ExpandProperty FullName)
}

if ($fixtures.Count -eq 0) {
    Write-Warning "No test fixtures found in $FixtureDir"
    exit 1
}

foreach ($f in $fixtures) {
    if (-not (Test-Path $f)) {
        Write-Warning "Fixture not found: $f"
        continue
    }
    Run-FixtureFile -FilePath $f
}

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
Write-Host "`n--- Summary ---" -ForegroundColor White
Write-Host "  Total  : $Total"
Write-Host "  Passed : $Passed" -ForegroundColor Green
Write-Host "  Failed : $Failed" -ForegroundColor Red
if ($Skipped -gt 0) {
    Write-Host "  Info   : $Skipped" -ForegroundColor Yellow
}

if ($Failed -gt 0) {
    Write-Host "`n  SOME TESTS FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`n  ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}
