# =============================================================
# test-masking.ps1
# Cross-platform test runner for masking-config.json patterns
# Works on: Windows PowerShell 5.1+, PowerShell Core 7+ (Win/Mac/Linux)
# No external dependencies required (pure PowerShell regex testing)
#
# Usage:
#   .\tests\test-masking.ps1
#   .\tests\test-masking.ps1 -FixturePath .\tests\fixtures\test-sample-patterns.json
#   .\tests\test-masking.ps1 -ConfigPath .\cli\hooks\masking-config.json
# =============================================================
param(
    [string]$FixturePath = "",
    [string]$ProjectRoot = "",
    [string]$ConfigPath = ""
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

$FixtureDir = Join-Path $ProjectRoot "tests\fixtures"
$LibraryPath = Join-Path $ProjectRoot "cli\lib\mask-data-tools.ps1"

if (-not (Test-Path $LibraryPath -PathType Leaf)) {
    Write-Error "Library not found: $LibraryPath"
    exit 1
}

. $LibraryPath

try {
    $ResolvedConfigPath = Resolve-DefaultMaskDataConfigPath -ConfigPath $ConfigPath -WorkspaceRoot $ProjectRoot
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

# ------------------------------------------------------------------
# Load config patterns
# ------------------------------------------------------------------
$config = Read-MaskDataConfig -ConfigPath $ResolvedConfigPath
$activePatterns = Get-ActiveMaskPatterns -Config $config

function Invoke-Mask {
    param([string]$Content)

    return (Invoke-MaskDataText -Text $Content -Patterns $activePatterns)
}

function Test-HasSensitive {
    param([string]$Content)

    return ((Get-MaskDataMatchedPatterns -Text $Content -Patterns $activePatterns).Count -gt 0)
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
Write-Host "  Config     : $ResolvedConfigPath" -ForegroundColor DarkGray

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
