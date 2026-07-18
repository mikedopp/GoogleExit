<#
.SYNOPSIS
    Pulls all Gmail + Google Drive (incl. Docs/Sheets/Slides) for ONE Google
    account down to a local drive. Run it once per account, pointing -Dest at
    that person's hard drive.

.EXAMPLE
    .\Invoke-GoogleExport.ps1 -Email mike.dopp@gmail.com -Dest F:\GoogleBackup

.EXAMPLE
    # Kid's account onto their own drive
    .\Invoke-GoogleExport.ps1 -Email kid@gmail.com -Dest E:\

.EXAMPLE
    # Re-run later to top up (both tools are incremental/resumable)
    .\Invoke-GoogleExport.ps1 -Email mike.dopp@gmail.com -Dest F:\GoogleBackup -SkipGmail

.NOTES
    First run per account opens a browser for Google sign-in (sign in as THAT
    account). Google Photos and Android device backups cannot be pulled by API
    at full quality anymore - use https://takeout.google.com for those.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Email,
    [Parameter(Mandatory)][string]$Dest,
    [switch]$SkipGmail,
    [switch]$SkipDrive,
    [switch]$IncludeSharedWithMe,
    [string]$ToolsDir = "F:\mikedopp\drop\GoogleExit\tools"
)

$ErrorActionPreference = 'Stop'

# ---------- layout ----------
$acctSlug  = ($Email -replace '@.*$','') -replace '[^a-zA-Z0-9]', '-'
$acctRoot  = Join-Path $Dest $Email
$driveDest = Join-Path $acctRoot 'Drive'
$sharedDest= Join-Path $acctRoot 'SharedWithMe'
$gmailDest = Join-Path $acctRoot 'Gmail'
$logDir    = Join-Path $acctRoot 'logs'
$stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'

New-Item -ItemType Directory -Force -Path $acctRoot, $logDir | Out-Null
Start-Transcript -Path (Join-Path $logDir "run-$stamp.txt") | Out-Null

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# ---------- tool: rclone ----------
function Get-Rclone {
    $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $local = Join-Path $ToolsDir 'rclone\rclone.exe'
    if (Test-Path $local) { return $local }

    Write-Step "Installing rclone (winget)"
    winget install --id Rclone.Rclone -e --accept-source-agreements --accept-package-agreements | Out-Host
    # winget puts it on PATH for new shells; find it for this one
    $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $found = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    throw "rclone installed but not found - open a new terminal and re-run."
}

# ---------- tool: GYB (Got Your Back) ----------
function Get-Gyb {
    $exe = Join-Path $ToolsDir 'gyb\gyb.exe'
    if (Test-Path $exe) { return $exe }

    Write-Step "Downloading GYB (Got Your Back) from GitHub"
    New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
    $rel = Invoke-RestMethod 'https://api.github.com/repos/GAM-team/got-your-back/releases/latest'
    $asset = $rel.assets | Where-Object { $_.name -match 'windows' -and $_.name -match 'x86_64' -and $_.name -match '\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw "Could not find a Windows GYB release asset. Download manually: https://github.com/GAM-team/got-your-back/releases" }
    $zip = Join-Path $ToolsDir $asset.name
    Write-Host "  $($asset.name) ($([math]::Round($asset.size/1MB,1)) MB)"
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip
    Expand-Archive $zip -DestinationPath (Join-Path $ToolsDir 'gyb') -Force
    Remove-Item $zip
    # some releases nest a gyb\ folder inside the zip
    if (-not (Test-Path $exe)) {
        $nested = Get-ChildItem (Join-Path $ToolsDir 'gyb') -Recurse -Filter gyb.exe | Select-Object -First 1
        if ($nested) { $exe = $nested.FullName }
    }
    if (-not (Test-Path $exe)) { throw "GYB unzip failed - check $ToolsDir" }
    return $exe
}

# ---------- Drive via rclone ----------
if (-not $SkipDrive) {
    $rclone = Get-Rclone
    $remote = "gdrive-$acctSlug"

    $existing = & $rclone listremotes
    if ($existing -notcontains "${remote}:") {
        Write-Step "Authorizing Google Drive for $Email (browser will open - sign in as $Email)"
        & $rclone config create $remote drive scope=drive.readonly
        if ($LASTEXITCODE -ne 0) { throw "rclone remote setup failed" }
    }

    Write-Step "Copying Drive -> $driveDest (Docs->docx, Sheets->xlsx, Slides->pptx)"
    & $rclone copy "${remote}:" $driveDest `
        --drive-export-formats docx,xlsx,pptx,svg `
        --drive-acknowledge-abuse `
        --create-empty-src-dirs `
        --transfers 4 --checkers 8 `
        --progress `
        --log-file (Join-Path $logDir "rclone-drive-$stamp.log") --log-level INFO
    if ($LASTEXITCODE -ne 0) { Write-Warning "rclone finished with errors - see logs\rclone-drive-$stamp.log (often just files Google refuses to export; re-run to retry)" }

    if ($IncludeSharedWithMe) {
        Write-Step "Copying 'Shared with me' -> $sharedDest"
        & $rclone copy "${remote}:" $sharedDest `
            --drive-shared-with-me `
            --drive-export-formats docx,xlsx,pptx,svg `
            --drive-acknowledge-abuse `
            --transfers 4 --progress `
            --log-file (Join-Path $logDir "rclone-shared-$stamp.log") --log-level INFO
    }
}

# ---------- Gmail via GYB ----------
if (-not $SkipGmail) {
    $gyb = Get-Gyb
    Write-Step "Backing up Gmail for $Email -> $gmailDest"
    Write-Host "First run per account: GYB walks you through a one-time Google Cloud project + browser sign-in. Just follow its prompts." -ForegroundColor Yellow
    & $gyb --email $Email --action backup --local-folder $gmailDest
    if ($LASTEXITCODE -ne 0) { Write-Warning "GYB exited with errors - re-run, it resumes where it left off." }

    Write-Step "Gmail message count check"
    & $gyb --email $Email --action count
}

# ---------- summary ----------
Write-Step "Done: $Email"
Write-Host @"
Saved under: $acctRoot
  Drive\   - all Drive files, Google Docs converted to Office formats
  Gmail\   - full mailbox archive (GYB format; restorable or exportable to mbox)
  logs\    - transfer logs

Still need Google Takeout (https://takeout.google.com) for:
  - Google Photos (API downloads are no longer full quality)
  - Android device backups
  - YouTube, Maps history, etc.

Re-running this script is safe - it only fetches new/changed items.
"@
Stop-Transcript | Out-Null
