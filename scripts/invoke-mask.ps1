# =============================================================
# invoke-mask.ps1
# Rename files with sensitive names (pure digits 9-16) to
# masked aliases before starting a Copilot session.
#
# Windows : .\invoke-mask.ps1
# macOS   : pwsh invoke-mask.ps1
# With arg: pwsh invoke-mask.ps1 -WorkspaceRoot "/path/to/project"
# =============================================================
param(
    [string]$WorkspaceRoot = (Get-Location).Path
)

$WorkspaceRoot = $WorkspaceRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, '/', '\')
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
# Scan for sensitive filenames
# ------------------------------------------------------------------
$renames = @()

Get-ChildItem -Path $WorkspaceRoot -Recurse -File | ForEach-Object {
    $baseName = [IO.Path]::GetFileNameWithoutExtension($_.Name)
    $ext      = $_.Extension

    if ($baseName -match $pattern) {
        $sha1    = [Security.Cryptography.SHA1]::Create()
        $bytes   = [Text.Encoding]::UTF8.GetBytes($_.FullName)
        $hash    = [BitConverter]::ToString($sha1.ComputeHash($bytes)).Replace('-','').Substring(0,8).ToLower()
        $newName = "masked-$hash$ext"
        $newPath = Join-Path $_.DirectoryName $newName

        $renames += [PSCustomObject]@{
            originalPath = $_.FullName
            maskedPath   = $newPath
            originalName = $_.Name
            maskedName   = $newName
        }
    }
}

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

    foreach ($r in $renames) {
        $relPath = $r.originalPath.Substring($WorkspaceRoot.Length).TrimStart('\', '/').Replace('\', '/')
        git -C $WorkspaceRoot update-index --skip-worktree -- $relPath 2>&1 | Out-Null
    }
    Write-Host "[invoke-mask] Applied git skip-worktree on $($renames.Count) file(s)" -ForegroundColor Gray
}

# ------------------------------------------------------------------
# Rename files
# ------------------------------------------------------------------
$succeeded = @()
foreach ($r in $renames) {
    try {
        Rename-Item -Path $r.originalPath -NewName $r.maskedName -ErrorAction Stop
        $succeeded += $r
        Write-Host "[invoke-mask] $($r.originalName) -> $($r.maskedName)" -ForegroundColor Cyan
    } catch {
        Write-Warning "[invoke-mask] Failed: $($r.originalPath) — $_"
    }
}

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
