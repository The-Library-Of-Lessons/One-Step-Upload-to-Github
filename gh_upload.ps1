param(
    [Parameter(Position = 0)]
    [string]$FilePath,

    [Parameter(Position = 1)]
    [string]$GitHubUrl
)

$ErrorActionPreference = "Stop"

# Support cmd.exe `set "FILE=..." & set "URL=..."` as well as positional args or prompts
if ([string]::IsNullOrWhiteSpace($FilePath) -and $env:FILE) { $FilePath = $env:FILE }
if ([string]::IsNullOrWhiteSpace($GitHubUrl) -and $env:URL) { $GitHubUrl = $env:URL }

if ([string]::IsNullOrWhiteSpace($FilePath)) {
    $FilePath = Read-Host "Paste local file path"
}
if ([string]::IsNullOrWhiteSpace($GitHubUrl)) {
    $GitHubUrl = Read-Host "Paste GitHub folder URL"
}

$FilePath  = $FilePath.Trim().Trim('"')
$GitHubUrl = $GitHubUrl.Trim().Trim('"')

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "'git' is not recognized. Install Git for Windows and reopen Command Prompt."
    exit 1
}

if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
    Write-Error "Local file not found: $FilePath"
    exit 1
}

try {
    $uri = [System.Uri]$GitHubUrl
} catch {
    Write-Error "Invalid GitHub URL: $GitHubUrl"
    exit 1
}

$parts = $uri.AbsolutePath.Trim('/').Split('/') | Where-Object { $_ -ne "" }
if ($parts.Count -lt 2) {
    Write-Error "URL must point to a GitHub repository (https://github.com/owner/repo...)."
    exit 1
}

$owner    = $parts[0]
$repoName = $parts[1] -replace '\.git$', ''
$repoUrl  = "https://github.com/$owner/$repoName.git"

$branch = "main"
$folder = ""
if ($parts.Count -ge 4 -and $parts[2] -eq "tree") {
    $branch = [uri]::UnescapeDataString($parts[3])
    if ($parts.Count -gt 4) {
        $folder = [uri]::UnescapeDataString(($parts[4..($parts.Count - 1)] -join "/"))
    }
}

$fileName = [System.IO.Path]::GetFileName($FilePath)
$tempDir  = Join-Path ([System.IO.Path]::GetTempPath()) ("gh_upload_" + [System.Guid]::NewGuid().ToString("N"))

function Invoke-Git {
    param([string[]]$GitArgs)
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs[0]) failed with exit code $LASTEXITCODE"
    }
}

try {
    Write-Host "[1/4] Cloning $owner/$repoName (branch: $branch)..." -ForegroundColor Cyan
    Invoke-Git @("clone", "--depth", "1", "--branch", $branch, "--filter=blob:none", "--no-checkout", $repoUrl, $tempDir)

    if ($folder) {
        Invoke-Git @("-C", $tempDir, "sparse-checkout", "init", "--cone")
        Invoke-Git @("-C", $tempDir, "sparse-checkout", "set", $folder)
    }
    Invoke-Git @("-C", $tempDir, "checkout", $branch)

    Write-Host "[2/4] Copying $fileName..." -ForegroundColor Cyan
    if ($folder) {
        $destDir = Join-Path $tempDir ($folder -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        $destFile = Join-Path $destDir $fileName
        $relPath  = "$folder/$fileName"
    } else {
        $destFile = Join-Path $tempDir $fileName
        $relPath  = $fileName
    }
    Copy-Item -LiteralPath $FilePath -Destination $destFile -Force

    Write-Host "[3/4] Committing $relPath..." -ForegroundColor Cyan
    Invoke-Git @("-C", $tempDir, "add", $relPath)
    Invoke-Git @("-C", $tempDir, "commit", "-m", "Add $fileName")

    Write-Host "[4/4] Pushing to origin/$branch..." -ForegroundColor Cyan
    Invoke-Git @("-C", $tempDir, "push", "origin", $branch)

    Write-Host "Done! Uploaded $fileName to $GitHubUrl" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
