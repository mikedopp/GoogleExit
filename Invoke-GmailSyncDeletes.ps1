<#
.SYNOPSIS
    DESTRUCTIVE (server-side). Applies MailVault archive purges to the live
    Gmail account: every message you permanently deleted in MailVault gets
    permanently deleted from Gmail too, matched by Message-ID.

    Guards:
      - dry-run count per batch shown BEFORE anything is deleted
      - requires typing the full email address to proceed
      - processed manifest is archived (renamed), never re-applied

.EXAMPLE
    # See what would be deleted, delete nothing:
    .\Invoke-GmailSyncDeletes.ps1 -Email mike.dopp@gmail.com -Dest N:\GoogleExport -DryRun

.EXAMPLE
    .\Invoke-GmailSyncDeletes.ps1 -Email mike.dopp@gmail.com -Dest N:\GoogleExport
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Email,
    [Parameter(Mandatory)][string]$Dest,
    [switch]$DryRun,
    [int]$BatchSize = 20,
    [string]$ToolsDir = "F:\mikedopp\drop\GoogleExit\tools"
)

$ErrorActionPreference = 'Stop'

$gyb = Get-ChildItem (Join-Path $ToolsDir 'gyb') -Recurse -Filter gyb.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $gyb) { throw "GYB not found under $ToolsDir - run Invoke-GoogleExport.ps1 first." }

$gmailDir = Join-Path (Join-Path $Dest $Email) 'Gmail'
$manifest = Join-Path $gmailDir '_PurgedFromArchive.jsonl'
if (-not (Test-Path $manifest)) {
    throw "No purge manifest at $manifest - nothing has been purged in MailVault for this account (or wrong -Dest)."
}

$entries = Get-Content $manifest | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }
$withId = @($entries | Where-Object { $_.messageId })
$noId   = @($entries | Where-Object { -not $_.messageId })

Write-Host "Manifest: $($entries.Count) purged message(s); $($withId.Count) with a Message-ID, $($noId.Count) unmatchable (no Message-ID header)." -ForegroundColor Cyan
if ($noId.Count) {
    Write-Host "Unmatchable ones stay on the server; delete them manually if they matter:" -ForegroundColor Yellow
    $noId | ForEach-Object { Write-Host ("  {0} | {1}" -f $_.sender, $_.subject) }
}
if (-not $withId.Count) { Write-Host "Nothing to sync."; return }

# batch into rfc822msgid: OR-queries
$batches = @()
for ($i = 0; $i -lt $withId.Count; $i += $BatchSize) {
    $chunk = $withId[$i..([Math]::Min($i + $BatchSize, $withId.Count) - 1)]
    $batches += ,@{
        query = ($chunk | ForEach-Object { "rfc822msgid:$($_.messageId)" }) -join ' OR '
        items = $chunk
    }
}

# ---------- dry run: count server-side matches ----------
Write-Host "`nCounting matches on the server (no deletion yet)..." -ForegroundColor Cyan
$totalMatches = 0
foreach ($b in $batches) {
    $out = & $gyb --email $Email --action estimate --search $b.query 2>&1 | Out-String
    if ($out -match 'needs to examine\s+(\d+)') { $n = [int]$Matches[1] } else { $n = -1 }
    $totalMatches += [Math]::Max($n, 0)
    Write-Host ("  batch of {0}: {1} match(es) on server" -f $b.items.Count, $(if ($n -ge 0) { $n } else { "?" }))
}
Write-Host "Server-side total to delete: $totalMatches (manifest expected $($withId.Count); fewer just means some are already gone)" -ForegroundColor Cyan

if ($DryRun) { Write-Host "`n-DryRun: stopping here. Nothing was deleted." -ForegroundColor Green; return }
if ($totalMatches -eq 0) { Write-Host "Nothing left on the server to delete."; return }

# ---------- confirmation ----------
Write-Host ""
Write-Host "#########################################################" -ForegroundColor Red
Write-Host "  PERMANENTLY DELETE $totalMatches message(s) from the" -ForegroundColor Red
Write-Host "  LIVE Gmail account $Email (no trash, not recoverable)" -ForegroundColor Red
Write-Host "#########################################################" -ForegroundColor Red
$answer = Read-Host "Type the full email address to confirm"
if ($answer -cne $Email) { throw "Confirmation did not match. Nothing was deleted." }

# ---------- purge ----------
$done = 0
foreach ($b in $batches) {
    & $gyb --email $Email --action purge --search $b.query
    if ($LASTEXITCODE -ne 0) { Write-Warning "purge batch reported an error - re-run this script to retry; already-deleted messages are skipped automatically." }
    $done += $b.items.Count
    Write-Host ("  purged batch ({0}/{1} manifest entries processed)" -f $done, $withId.Count)
}

# ---------- archive the manifest so it is never re-applied ----------
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Move-Item $manifest "$manifest.synced-$stamp"
Write-Host "`nDone. Manifest archived as _PurgedFromArchive.jsonl.synced-$stamp" -ForegroundColor Green
Write-Host "New MailVault purges will start a fresh manifest."
