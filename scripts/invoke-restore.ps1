# =============================================================
# invoke-restore.ps1
# Restore original sensitive filenames after Copilot session.
#
# Windows : .\invoke-restore.ps1
# macOS   : pwsh invoke-restore.ps1
# With arg: pwsh invoke-restore.ps1 -WorkspaceRoot "/path/to/project"
#           -ShowDetails  (print every restored file)
# =============================================================
param(
    [string]$WorkspaceRoot = (Get-Location).Path,
    [switch]$ShowDetails
)

$WorkspaceRoot = (Resolve-Path $WorkspaceRoot).Path.TrimEnd([IO.Path]::DirectorySeparatorChar, '/', '\')
$sep           = [IO.Path]::DirectorySeparatorChar
$mappingFile   = Join-Path $WorkspaceRoot ".github${sep}hooks${sep}.masked-files.json"

# ------------------------------------------------------------------
# Check mapping exists
# ------------------------------------------------------------------
if (-not (Test-Path $mappingFile)) {
    Write-Host "[invoke-restore] No mapping file found. Nothing to restore." -ForegroundColor Yellow
    exit 0
}

# ------------------------------------------------------------------
# Load mapping
# ------------------------------------------------------------------
try {
    $mapping = Get-Content -Path $mappingFile -Raw | ConvertFrom-Json
} catch {
    Write-Error "[invoke-restore] Failed to parse mapping file: $_"
    exit 1
}

$files = $mapping.files
if (-not $files -or $files.Count -eq 0) {
    Write-Host "[invoke-restore] Mapping is empty. Nothing to restore." -ForegroundColor Yellow
    Remove-Item $mappingFile -Force
    exit 0
}

# ------------------------------------------------------------------
# Restore files (progress bar + ETA)
# ------------------------------------------------------------------
$restored    = 0
$failed      = 0
$restoreTotal = $files.Count
$sw           = [System.Diagnostics.Stopwatch]::StartNew()

try {
    for ($j = 0; $j -lt $restoreTotal; $j++) {
        $r = $files[$j]

        $elapsed = $sw.Elapsed.TotalSeconds
        $rate    = if ($elapsed -gt 0) { ($j + 1) / $elapsed } else { [double]($j + 1) }
        $eta     = if ($rate -gt 0)    { [int](($restoreTotal - $j - 1) / $rate) } else { 0 }

        Write-Progress `
            -Activity         'Restoring original filenames' `
            -Status           "$($j + 1) / $restoreTotal  |  ETA: ${eta}s" `
            -CurrentOperation "$($r.maskedName) → $($r.originalName)" `
            -PercentComplete  ([int](($j + 1) / $restoreTotal * 100)) `
            -SecondsRemaining $eta

        if (-not (Test-Path $r.maskedPath)) {
            Write-Warning "[invoke-restore] Not found (skipping): $($r.maskedPath)"
            $failed++
            continue
        }
        try {
            Rename-Item -Path $r.maskedPath -NewName $r.originalName -ErrorAction Stop
            $restored++
            if ($ShowDetails) {
                Write-Host "[invoke-restore] $($r.maskedName) -> $($r.originalName)" -ForegroundColor Green
            }
        } catch {
            Write-Warning "[invoke-restore] Failed: $($r.maskedPath) — $_"
            $failed++
        }
    }
} finally {
    Write-Progress -Activity 'Restoring original filenames' -Completed
    $sw.Stop()
}

$restoreSecs = [math]::Round($sw.Elapsed.TotalSeconds, 2)
Write-Host "[invoke-restore] Restore complete in ${restoreSecs}s." -ForegroundColor Gray

# ------------------------------------------------------------------
# Remove mapping file
# ------------------------------------------------------------------
Remove-Item $mappingFile -Force

# ------------------------------------------------------------------
# Git: undo skip-worktree (batched — one git call per 500 files)
# ------------------------------------------------------------------
$isGitRepo = Test-Path (Join-Path $WorkspaceRoot ".git")
if ($isGitRepo) {
    $relPaths  = $files | ForEach-Object {
        $_.originalPath.Substring($WorkspaceRoot.Length).TrimStart('\', '/').Replace('\', '/')
    }
    $batchSize = 500
    for ($k = 0; $k -lt $relPaths.Count; $k += $batchSize) {
        $batch = $relPaths[$k .. ([Math]::Min($k + $batchSize - 1, $relPaths.Count - 1))]
        git -C $WorkspaceRoot update-index --no-skip-worktree -- @batch 2>&1 | Out-Null
    }
    Write-Host "[invoke-restore] Removed git skip-worktree on $($files.Count) file(s)" -ForegroundColor Gray
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "[invoke-restore] Done. $restored file(s) restored." -ForegroundColor Green
} else {
    Write-Warning "[invoke-restore] Done. $restored restored, $failed failed."
    exit 1
}
