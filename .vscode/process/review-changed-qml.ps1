param(
    [switch]$StagedOnly,
    [switch]$UnstagedOnly
)

$ErrorActionPreference = 'Stop'

$projectRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$isGitRepo = cmd /c "git -C \"$projectRoot\" rev-parse --is-inside-work-tree 2>nul"

if ($LASTEXITCODE -ne 0 -or $isGitRepo -ne "true") {
    Write-Host "This helper needs a Git working tree to detect changed files."
    Write-Host "Project root checked: $projectRoot"
    Write-Host "Run it inside a cloned Git repository or review files manually."
    exit 0
}

if ($StagedOnly -and $UnstagedOnly) {
    Write-Error "Use either -StagedOnly or -UnstagedOnly, not both."
    exit 1
}

function Get-ChangedQmlFiles {
    param(
        [switch]$IncludeStaged,
        [switch]$IncludeUnstaged
    )

    $files = @()

    if ($IncludeUnstaged) {
        $unstaged = git -C $projectRoot diff --name-only -- '*.qml'
        if ($LASTEXITCODE -eq 0 -and $unstaged) {
            $files += $unstaged
        }
    }

    if ($IncludeStaged) {
        $staged = git -C $projectRoot diff --cached --name-only -- '*.qml'
        if ($LASTEXITCODE -eq 0 -and $staged) {
            $files += $staged
        }
    }

    return $files | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique
}

$includeStaged = $true
$includeUnstaged = $true

if ($StagedOnly) {
    $includeUnstaged = $false
}

if ($UnstagedOnly) {
    $includeStaged = $false
}

$files = Get-ChangedQmlFiles -IncludeStaged:$includeStaged -IncludeUnstaged:$includeUnstaged

if (-not $files -or $files.Count -eq 0) {
    Write-Host "No changed QML files found for the selected scope."
    exit 0
}

Write-Host "Changed QML files:"
$files | ForEach-Object { Write-Host "- $_" }

$fileList = ($files | ForEach-Object { "- $_" }) -join "`n"

Write-Host ""
Write-Host "Paste this prompt into Copilot Chat:"
Write-Host ""
Write-Host "Use @qt-qml-review to review these changed QML files only. Report only high-confidence findings with file and line references, ordered by severity:"
Write-Host $fileList
