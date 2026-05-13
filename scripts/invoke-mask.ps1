# =============================================================
# invoke-mask.ps1
# Rename files with sensitive names (pure digits 9-16) to
# masked aliases before starting a Copilot session.
#
# Windows : .\invoke-mask.ps1
# macOS   : pwsh invoke-mask.ps1
# With arg: pwsh invoke-mask.ps1 -WorkspaceRoot "/path/to/project"
#           -ShowDetails  (print every renamed file)
# =============================================================
param(
    [string]$WorkspaceRoot = (Get-Location).Path,
    [switch]$ShowDetails
)

$WorkspaceRoot = (Resolve-Path $WorkspaceRoot).Path.TrimEnd([IO.Path]::DirectorySeparatorChar, '/', '\')
$sep           = [IO.Path]::DirectorySeparatorChar
$mappingFile   = Join-Path $WorkspaceRoot ".github${sep}hooks${sep}.masked-files.json"
$pattern       = '^\d{9,16}$'

# ------------------------------------------------------------------
# Safety: if a mapping already exists, restore first
# ------------------------------------------------------------------
if (Test-Path $mappingFile) {
    Write-Host "[invoke-mask] Found existing mapping — running restore first..." -ForegroundColor Yellow
    & (Join-Path $PSScriptRoot "invoke-restore.ps1") -WorkspaceRoot $WorkspaceRoot
}

# ------------------------------------------------------------------
# Collect all files upfront — required to show accurate progress
# ------------------------------------------------------------------
Write-Host "[invoke-mask] Collecting file list from: $WorkspaceRoot" -ForegroundColor Gray
$allFiles   = @(Get-ChildItem -Path $WorkspaceRoot -Recurse -File)
$totalFiles = $allFiles.Count
Write-Host "[invoke-mask] $totalFiles file(s) to scan." -ForegroundColor Gray

# ------------------------------------------------------------------
# Scan for sensitive filenames (progress bar + ETA)
# ------------------------------------------------------------------
# Performance notes vs. original:
#   • MD5 instance created ONCE and reused  (was: new SHA1 per file → huge GC pressure)
#   • List[T].Add() instead of $array +=    (was: O(n²) copy-on-every-append)
$hasher    = [System.Security.Cryptography.MD5]::Create()
$renames   = [System.Collections.Generic.List[PSCustomObject]]::new()
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    for ($i = 0; $i -lt $totalFiles; $i++) {
        $file = $allFiles[$i]

        # --- progress bar ---
        $elapsed = $stopwatch.Elapsed.TotalSeconds
        $rate    = if ($elapsed -gt 0) { ($i + 1) / $elapsed } else { [double]($i + 1) }
        $eta     = if ($rate -gt 0)    { [int](($totalFiles - $i - 1) / $rate) } else { 0 }

        Write-Progress `
            -Activity         'Scanning for sensitive filenames' `
            -Status           "$($i + 1) / $totalFiles  |  Found: $($renames.Count)  |  ETA: ${eta}s" `
            -CurrentOperation $file.Name `
            -PercentComplete  ([int](($i + 1) / $totalFiles * 100)) `
            -SecondsRemaining $eta

        # --- check filename ---
        $baseName = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        $ext      = $file.Extension

        if ($baseName -match $pattern) {
            $bytes   = [Text.Encoding]::UTF8.GetBytes($file.FullName)
            $hash    = [BitConverter]::ToString($hasher.ComputeHash($bytes)).Replace('-', '').Substring(0, 8).ToLower()
            $newName = "masked-$hash$ext"
            $newPath = Join-Path $file.DirectoryName $newName
            # Store forward-slash relative paths so invoke-restore.sh
            # works cross-platform without any path format conversion.
            $relDir  = $file.DirectoryName.Substring($WorkspaceRoot.Length).TrimStart('\', '/').Replace('\', '/')

            $renames.Add([PSCustomObject]@{
                originalPath    = $file.FullName
                maskedPath      = $newPath
                originalName    = $file.Name
                maskedName      = $newName
                originalRelPath = if ($relDir) { "$relDir/$($file.Name)" } else { $file.Name }
                maskedRelPath   = if ($relDir) { "$relDir/$newName" }      else { $newName }
            })
        }
    }
} finally {
    Write-Progress -Activity 'Scanning for sensitive filenames' -Completed
    $hasher.Dispose()
    $stopwatch.Stop()
}

$scanSecs = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
Write-Host "[invoke-mask] Scan complete in ${scanSecs}s — $($renames.Count) sensitive file(s) found." -ForegroundColor Gray

if ($renames.Count -eq 0) {
    Write-Host "[invoke-mask] No sensitive filenames found. Nothing to do." -ForegroundColor Green
    exit 0
}

# ------------------------------------------------------------------
# Git: skip-worktree + ensure masked-* is gitignored
# ------------------------------------------------------------------
$isGitRepo = Test-Path (Join-Path $WorkspaceRoot ".git")

if ($isGitRepo) {
    $gitignorePath = Join-Path $WorkspaceRoot ".gitignore"
    $ignoreEntry   = "masked-*"
    $mappingEntry  = ".github/hooks/.masked-files.json"
    $existing      = if (Test-Path $gitignorePath) { Get-Content $gitignorePath } else { @() }

    $toAdd = @()
    if ($existing -notcontains $ignoreEntry)  { $toAdd += $ignoreEntry }
    if ($existing -notcontains $mappingEntry) { $toAdd += $mappingEntry }
    if ($toAdd.Count -gt 0) {
        $block = "`n# Temporary masked aliases (invoke-mask / invoke-restore)`n" + ($toAdd -join "`n")
        Add-Content -Path $gitignorePath -Value $block
        Write-Host "[invoke-mask] .gitignore updated: $($toAdd -join ', ')" -ForegroundColor Gray
    }

    # Performance: batch all paths into one git call per 500 files instead of
    # spawning a separate git process for every file (was: N process spawns).
    $relPaths  = $renames | ForEach-Object {
        $_.originalPath.Substring($WorkspaceRoot.Length).TrimStart('\', '/').Replace('\', '/')
    }
    $batchSize = 500
    for ($k = 0; $k -lt $relPaths.Count; $k += $batchSize) {
        $batch = $relPaths[$k .. ([Math]::Min($k + $batchSize - 1, $relPaths.Count - 1))]
        git -C $WorkspaceRoot update-index --skip-worktree -- @batch 2>&1 | Out-Null
    }
    Write-Host "[invoke-mask] Applied git skip-worktree on $($renames.Count) file(s)" -ForegroundColor Gray
}

# ------------------------------------------------------------------
# Rename files (progress bar + ETA)
# ------------------------------------------------------------------
$succeeded   = [System.Collections.Generic.List[PSCustomObject]]::new()
$renameTotal = $renames.Count
$sw2         = [System.Diagnostics.Stopwatch]::StartNew()

try {
    for ($j = 0; $j -lt $renameTotal; $j++) {
        $r = $renames[$j]

        $elapsed2 = $sw2.Elapsed.TotalSeconds
        $rate2    = if ($elapsed2 -gt 0) { ($j + 1) / $elapsed2 } else { [double]($j + 1) }
        $eta2     = if ($rate2 -gt 0)    { [int](($renameTotal - $j - 1) / $rate2) } else { 0 }

        Write-Progress `
            -Activity         'Renaming sensitive files' `
            -Status           "$($j + 1) / $renameTotal  |  ETA: ${eta2}s" `
            -CurrentOperation "$($r.originalName) → $($r.maskedName)" `
            -PercentComplete  ([int](($j + 1) / $renameTotal * 100)) `
            -SecondsRemaining $eta2

        try {
            Rename-Item -Path $r.originalPath -NewName $r.maskedName -ErrorAction Stop
            $succeeded.Add($r)
            if ($ShowDetails) {
                Write-Host "[invoke-mask] $($r.originalName) -> $($r.maskedName)" -ForegroundColor Cyan
            }
        } catch {
            Write-Warning "[invoke-mask] Failed: $($r.originalPath) — $_"
        }
    }
} finally {
    Write-Progress -Activity 'Renaming sensitive files' -Completed
    $sw2.Stop()
}

$renameSecs = [math]::Round($sw2.Elapsed.TotalSeconds, 2)
Write-Host "[invoke-mask] Rename complete in ${renameSecs}s." -ForegroundColor Gray

# ------------------------------------------------------------------
# Save mapping (JSON)
# ------------------------------------------------------------------
$mappingDir = Split-Path $mappingFile -Parent
if (-not (Test-Path $mappingDir)) {
    New-Item -ItemType Directory -Path $mappingDir -Force | Out-Null
}

@{
    createdAt = (Get-Date).ToUniversalTime().ToString('o')
    workspace = $WorkspaceRoot
    files     = $succeeded
} | ConvertTo-Json -Depth 5 | Set-Content -Path $mappingFile -Encoding UTF8

Write-Host ""
Write-Host "[invoke-mask] Done. $($succeeded.Count) file(s) masked." -ForegroundColor Green
Write-Host "[invoke-mask] Mapping: $mappingFile" -ForegroundColor Gray
Write-Host "[invoke-mask] Run invoke-restore.ps1 when your Copilot session ends." -ForegroundColor Yellow
