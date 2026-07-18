<#
.SYNOPSIS
    DESTRUCTIVE. Empties a Google account's Drive and/or Gmail AFTER verifying
    the local backup made by Invoke-GoogleExport.ps1 is current.

    Order of operations per account:
      1. Top-up backup (re-runs the export script; incremental, fast)
      2. Show what's about to be deleted, with remote-vs-local counts
      3. Require you to TYPE THE EMAIL ADDRESS to confirm
      4. Drive: move everything to Drive trash, then empty the trash
      5. Gmail: GYB purge = permanent delete of all mail (inbox/sent/spam/trash)

.EXAMPLE
    .\Invoke-GoogleCleanup.ps1 -Email kid@gmail.com -Dest E:\

.EXAMPLE
    # Only wipe Gmail (the thing costing money), keep Drive for now
    .\Invoke-GoogleCleanup.ps1 -Email kid@gmail.com -Dest E:\ -SkipDrive

.NOTES
    Photos are NOT touched (script can't back them up - do Takeout first,
    then delete in photos.google.com). Storage quota updates within ~24h.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Email,
    [Parameter(Mandatory)][string]$Dest,
    [switch]$SkipGmail,
    [switch]$SkipDrive,
    [switch]$SkipTopUpBackup,
    [string]$ToolsDir = "F:\mikedopp\drop\GoogleExit\tools"
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$acctSlug = ($Email -replace '@.*$','') -replace '[^a-zA-Z0-9]', '-'
$acctRoot = Join-Path $Dest $Email
$logDir   = Join-Path $acctRoot 'logs'
$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'

function Write-Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# ---------- locate tools (installed by the export script) ----------
$rclone = (Get-Command rclone -ErrorAction SilentlyContinue)?.Source
if (-not $rclone) {
    $rclone = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
$gyb = Get-ChildItem (Join-Path $ToolsDir 'gyb') -Recurse -Filter gyb.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName

if (-not $SkipDrive -and -not $rclone) { throw "rclone not found - run Invoke-GoogleExport.ps1 first." }
if (-not $SkipGmail -and -not $gyb)   { throw "GYB not found - run Invoke-GoogleExport.ps1 first." }

# ---------- sanity: backup must exist ----------
if (-not (Test-Path $acctRoot)) {
    throw "No backup found at $acctRoot - run Invoke-GoogleExport.ps1 -Email $Email -Dest $Dest first. Refusing to delete anything."
}
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Start-Transcript -Path (Join-Path $logDir "cleanup-$stamp.txt") | Out-Null

# ---------- 1. top-up backup ----------
if (-not $SkipTopUpBackup) {
    Write-Step "Top-up backup before deleting (incremental)"
    & (Join-Path $scriptDir 'Invoke-GoogleExport.ps1') -Email $Email -Dest $Dest `
        -SkipGmail:$SkipGmail -SkipDrive:$SkipDrive -ToolsDir $ToolsDir
    if ($LASTEXITCODE -ne 0) { Write-Warning "Export script reported issues - review before continuing." }
}

# ---------- 2. show what will be deleted ----------
$remoteRO = "gdrive-$acctSlug"          # read-only remote from the export script
$remoteRW = "gdrive-$acctSlug-rw"       # read-write remote for deletion

if (-not $SkipDrive) {
    Write-Step "Drive contents about to be deleted (remote)"
    & $rclone size "${remoteRO}:"
    Write-Host "Local backup copy:" -ForegroundColor DarkGray
    $local = Join-Path $acctRoot 'Drive'
    if (Test-Path $local) {
        $m = Get-ChildItem $local -Recurse -File | Measure-Object -Sum Length
        Write-Host ("  {0} files, {1:N2} GB at {2}" -f $m.Count, ($m.Sum/1GB), $local)
    } else {
        Write-Warning "No local Drive backup at $local !"
    }
    Write-Host "Note: remote counts Google Docs at ~0 bytes; local .docx exports are bigger. File COUNTS should roughly match." -ForegroundColor DarkGray
}

if (-not $SkipGmail) {
    Write-Step "Gmail about to be PERMANENTLY deleted"
    & $gyb --email $Email --action count
    $db = Join-Path $acctRoot 'Gmail\msg-db.sqlite'
    if (-not (Test-Path $db)) { throw "No GYB backup database at $db - refusing to purge Gmail." }
    Write-Host "Local GYB archive present: $db" -ForegroundColor DarkGray
}

# ---------- 3. typed confirmation ----------
Write-Host ""
Write-Host "############################################################" -ForegroundColor Red
Write-Host "  THIS PERMANENTLY DELETES DATA FROM $Email" -ForegroundColor Red
if (-not $SkipDrive) { Write-Host "   - ALL Google Drive files (trashed, then trash emptied)" -ForegroundColor Red }
if (-not $SkipGmail) { Write-Host "   - ALL Gmail (inbox, sent, spam, trash - NOT recoverable)" -ForegroundColor Red }
Write-Host "  Verify the backup on $acctRoot yourself before proceeding." -ForegroundColor Red
Write-Host "############################################################" -ForegroundColor Red
$answer = Read-Host "Type the full email address to confirm"
if ($answer -cne $Email) {
    Stop-Transcript | Out-Null
    throw "Confirmation did not match. Nothing was deleted."
}

# ---------- 4. Drive wipe ----------
if (-not $SkipDrive) {
    $existing = & $rclone listremotes
    if ($existing -notcontains "${remoteRW}:") {
        Write-Step "Authorizing WRITE access to Drive for $Email (browser opens - sign in as $Email)"
        & $rclone config create $remoteRW drive scope=drive
        if ($LASTEXITCODE -ne 0) { throw "rclone read-write remote setup failed" }
    }

    Write-Step "Deleting all Drive files (to trash first)"
    & $rclone delete "${remoteRW}:" --rmdirs --progress `
        --log-file (Join-Path $logDir "rclone-delete-$stamp.log") --log-level INFO
    if ($LASTEXITCODE -ne 0) { Write-Warning "Some deletions failed - see log. Re-run to retry." }

    Write-Step "Emptying Drive trash (this is what actually frees the quota)"
    & $rclone cleanup "${remoteRW}:"
}

# ---------- 5. Gmail purge ----------
if (-not $SkipGmail) {
    Write-Step "Purging ALL Gmail for $Email (permanent)"
    & $gyb --email $Email --action purge --search "in:anywhere"
    if ($LASTEXITCODE -ne 0) { Write-Warning "Purge reported errors - re-run to retry." }

    Write-Step "Post-purge count (should be 0 or near 0)"
    & $gyb --email $Email --action count
}

# ---------- summary ----------
Write-Step "Cleanup finished for $Email"
Write-Host @"
Google's storage meter (one.google.com/storage) can take up to 24h to update.

Still on Google for this account (not touched by this script):
  - Google Photos: do Takeout first, then delete at photos.google.com
  - Anything in 'Shared with me' owned by other people (doesn't count
    against this account's quota anyway)

Local backup: $acctRoot  - consider a second copy before trusting one drive.
"@
Stop-Transcript | Out-Null
