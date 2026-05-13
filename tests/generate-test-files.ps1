# =============================================================
# generate-test-files.ps1
# Generate a large set of sample files to benchmark invoke-mask.ps1
#
# Usage:
#   .\tests\generate-test-files.ps1
#   .\tests\generate-test-files.ps1 -OutputDir "D:\tmp\bench" -TotalFiles 10000 -SensitiveRatio 0.3
#   .\tests\generate-test-files.ps1 -Clean        # remove OutputDir only
# =============================================================
param(
    [string] $OutputDir      = (Join-Path $PSScriptRoot "bench-workspace"),
    [int]    $TotalFiles     = 10000,
    [double] $SensitiveRatio = 0.30,   # 30 % = ~3000 sensitive files
    [switch] $Clean                    # just delete OutputDir and exit
)

# ------------------------------------------------------------------
# Clean mode
# ------------------------------------------------------------------
if ($Clean) {
    if (Test-Path $OutputDir) {
        Remove-Item -Recurse -Force $OutputDir
        Write-Host "[gen] Removed: $OutputDir" -ForegroundColor Green
    } else {
        Write-Host "[gen] Nothing to clean — $OutputDir does not exist." -ForegroundColor Gray
    }
    exit 0
}

# ------------------------------------------------------------------
# Config
# ------------------------------------------------------------------
$SensitiveCount = [int]($TotalFiles * $SensitiveRatio)
$NormalCount    = $TotalFiles - $SensitiveCount
$SubDirs        = @('invoices', 'receipts', 'docs', 'data', 'archive', 'exports',
                    'reports', 'uploads', 'temp', 'records')
$Extensions     = @('.json', '.xml', '.csv', '.txt', '.log', '.dat')
$NormalPrefixes = @('order', 'item', 'product', 'customer', 'record',
                    'export', 'report', 'log', 'event', 'entry')

$rng = [System.Random]::new()

# ------------------------------------------------------------------
# Create output directory
# ------------------------------------------------------------------
if (Test-Path $OutputDir) {
    Write-Host "[gen] Output dir already exists — files will be added/overwritten." -ForegroundColor Yellow
} else {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Create sub-directories
foreach ($d in $SubDirs) {
    New-Item -ItemType Directory -Path (Join-Path $OutputDir $d) -Force | Out-Null
}

Write-Host "[gen] Generating $TotalFiles files ($SensitiveCount sensitive + $NormalCount normal) in:"
Write-Host "      $OutputDir" -ForegroundColor Cyan
Write-Host ""

$sw    = [System.Diagnostics.Stopwatch]::StartNew()
$total = 0

# ------------------------------------------------------------------
# Helper: pick a random sub-directory
# ------------------------------------------------------------------
function Get-RandomDir {
    $sub = $SubDirs[$rng.Next(0, $SubDirs.Count)]
    return Join-Path $OutputDir $sub
}

# ------------------------------------------------------------------
# 1. Sensitive files — pure-digit names (9-16 digits)
# ------------------------------------------------------------------
Write-Progress -Activity 'Generating sensitive files' -Status "0 / $SensitiveCount" -PercentComplete 0

for ($i = 0; $i -lt $SensitiveCount; $i++) {
    $digitLen = $rng.Next(9, 17)          # 9..16 inclusive
    $digits   = -join (1..$digitLen | ForEach-Object { $rng.Next(0, 10) })
    $ext      = $Extensions[$rng.Next(0, $Extensions.Count)]
    $dir      = Get-RandomDir
    $path     = Join-Path $dir "$digits$ext"

    # Avoid collisions — append index suffix if needed
    if (Test-Path $path) { $path = Join-Path $dir "${digits}_${i}$ext" }

    [System.IO.File]::WriteAllText($path, '{}')

    $total++
    if ($i % 200 -eq 0) {
        $pct = [int](($i + 1) / $SensitiveCount * 100)
        $eta = if ($sw.Elapsed.TotalSeconds -gt 0) {
            [int](($SensitiveCount - $i - 1) / (($i + 1) / $sw.Elapsed.TotalSeconds))
        } else { 0 }
        Write-Progress -Activity 'Generating sensitive files' `
            -Status "$($i + 1) / $SensitiveCount  |  ETA: ${eta}s" `
            -PercentComplete $pct -SecondsRemaining $eta
    }
}
Write-Progress -Activity 'Generating sensitive files' -Completed

# ------------------------------------------------------------------
# 2. Normal files — human-readable names
# ------------------------------------------------------------------
Write-Progress -Activity 'Generating normal files' -Status "0 / $NormalCount" -PercentComplete 0

for ($i = 0; $i -lt $NormalCount; $i++) {
    $prefix = $NormalPrefixes[$rng.Next(0, $NormalPrefixes.Count)]
    $suffix = $rng.Next(1000, 99999)
    $ext    = $Extensions[$rng.Next(0, $Extensions.Count)]
    $dir    = Get-RandomDir
    $path   = Join-Path $dir "${prefix}-${suffix}$ext"

    if (Test-Path $path) { $path = Join-Path $dir "${prefix}-${suffix}_${i}$ext" }

    [System.IO.File]::WriteAllText($path, '{}')

    $total++
    if ($i % 200 -eq 0) {
        $pct = [int](($i + 1) / $NormalCount * 100)
        $eta = if ($sw.Elapsed.TotalSeconds -gt 0) {
            [int](($NormalCount - $i - 1) / (($i + 1) / $sw.Elapsed.TotalSeconds))
        } else { 0 }
        Write-Progress -Activity 'Generating normal files' `
            -Status "$($i + 1) / $NormalCount  |  ETA: ${eta}s" `
            -PercentComplete $pct -SecondsRemaining $eta
    }
}
Write-Progress -Activity 'Generating normal files' -Completed

$sw.Stop()

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
$actualSensitive = (Get-ChildItem $OutputDir -Recurse -File |
    Where-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) -match '^\d{9,16}$' }).Count

Write-Host ""
Write-Host "Done in $([math]::Round($sw.Elapsed.TotalSeconds, 2))s" -ForegroundColor Green
Write-Host "  Total files     : $total"
Write-Host "  Sensitive files : $actualSensitive  (names matching \d{9,16})"
Write-Host "  Normal files    : $($total - $actualSensitive)"
Write-Host ""
Write-Host "Run benchmark:" -ForegroundColor Yellow
Write-Host "  pwsh .\scripts\invoke-mask.ps1 -WorkspaceRoot `"$OutputDir`"" -ForegroundColor Cyan
Write-Host ""
Write-Host "Cleanup after test:" -ForegroundColor Yellow
Write-Host "  pwsh .\tests\generate-test-files.ps1 -Clean -OutputDir `"$OutputDir`"" -ForegroundColor Cyan
