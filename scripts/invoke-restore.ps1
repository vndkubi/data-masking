# =============================================================
# invoke-restore.ps1
# Restore original sensitive filenames after Copilot session.
#
# Windows : .\invoke-restore.ps1
# macOS   : pwsh invoke-restore.ps1
# With arg: pwsh invoke-restore.ps1 -WorkspaceRoot "/path/to/project"
# =============================================================
param(
    [string]$WorkspaceRoot = (Get-Location).Path
)

$WorkspaceRoot = $WorkspaceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, '/', '\')
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
# Restore files
# ------------------------------------------------------------------
$restored = 0
$failed   = 0

foreach ($r in $files) {
    if (-not (Test-Path $r.maskedPath)) {
        Write-Warning "[invoke-restore] Not found (skipping): $($r.maskedPath)"
        $failed++
        continue
    }
    try {
        Rename-Item -Path $r.maskedPath -NewName $r.originalName -ErrorAction Stop
        $restored++
        Write-Host "[invoke-restore] $($r.maskedName) -> $($r.originalName)" -ForegroundColor Green
    } catch {
        Write-Warning "[invoke-restore] Failed: $($r.maskedPath) — $_"
        $failed++
    }
}

# ------------------------------------------------------------------
# Remove mapping file
# ------------------------------------------------------------------
Remove-Item $mappingFile -Force

# ------------------------------------------------------------------
# Git: undo skip-worktree
# ------------------------------------------------------------------
$isGitRepo = Test-Path (Join-Path $WorkspaceRoot ".git")
if ($isGitRepo) {
    foreach ($r in $files) {
        $relPath = $r.originalPath.Substring($WorkspaceRoot.Length).TrimStart('\', '/').Replace('\', '/')
        git -C $WorkspaceRoot update-index --no-skip-worktree -- $relPath 2>&1 | Out-Null
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
