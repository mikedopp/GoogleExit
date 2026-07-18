<#
.SYNOPSIS
    Read-only inventory of everything in a Google Drive account.
    Flags Google-native items the API CANNOT export (My Maps, Forms, Sites...)
    with direct links so you can save them manually before wiping the drive.

.EXAMPLE
    .\Get-DriveInventory.ps1 -Email mike.dopp@gmail.com

.EXAMPLE
    .\Get-DriveInventory.ps1 -Email kid@gmail.com -Csv E:\kid-drive-inventory.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Email,
    [string]$Csv
)

$ErrorActionPreference = 'Stop'

$rclone = (Get-Command rclone -ErrorAction SilentlyContinue)?.Source
if (-not $rclone) {
    $rclone = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter rclone.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $rclone) { throw "rclone not found - run Invoke-GoogleExport.ps1 first." }

$acctSlug = ($Email -replace '@.*$','') -replace '[^a-zA-Z0-9]', '-'
$remote   = "gdrive-$acctSlug"
if ((& $rclone listremotes) -notcontains "${remote}:") {
    throw "No rclone remote '$remote' - run Invoke-GoogleExport.ps1 -Email $Email first to authorize."
}

Write-Host "Listing everything in Drive for $Email (read-only)..." -ForegroundColor Cyan
$json = & $rclone lsjson "${remote}:" -R --files-only --drive-show-all-gdocs --no-modtime 2>$null
if ($LASTEXITCODE -ne 0) { throw "rclone listing failed" }
$items = $json | ConvertFrom-Json

# Google-native types and whether the export script can save them
$gdocInfo = @{
    'application/vnd.google-apps.document'     = @{ Cat='Google Doc';      Export='YES -> .docx' }
    'application/vnd.google-apps.spreadsheet'  = @{ Cat='Google Sheet';    Export='YES -> .xlsx' }
    'application/vnd.google-apps.presentation' = @{ Cat='Google Slides';   Export='YES -> .pptx' }
    'application/vnd.google-apps.drawing'      = @{ Cat='Google Drawing';  Export='YES -> .svg' }
    'application/vnd.google-apps.map'          = @{ Cat='My Maps';         Export='NO - manual';  Link='https://www.google.com/maps/d/edit?mid={0}' }
    'application/vnd.google-apps.form'         = @{ Cat='Google Form';     Export='NO - manual';  Link='https://docs.google.com/forms/d/{0}/edit' }
    'application/vnd.google-apps.site'         = @{ Cat='Google Site';     Export='NO - manual';  Link='https://sites.google.com' }
    'application/vnd.google-apps.jam'          = @{ Cat='Jamboard';        Export='NO - manual';  Link='https://jamboard.google.com/d/{0}' }
    'application/vnd.google-apps.script'       = @{ Cat='Apps Script';     Export='NO - manual';  Link='https://script.google.com/d/{0}/edit' }
    'application/vnd.google-apps.shortcut'     = @{ Cat='Shortcut';        Export='n/a (just a pointer)' }
    'application/vnd.google-apps.folder'       = @{ Cat='Folder';          Export='n/a' }
}

$report = foreach ($i in $items) {
    $info = $gdocInfo[$i.MimeType]
    $cat  = if ($info) { $info.Cat } else { 'Regular file' }
    $exp  = if ($info) { $info.Export } else { 'YES - as-is' }
    $link = if ($info -and $info.Link) { $info.Link -f $i.ID } else { '' }
    [pscustomobject]@{
        Path       = $i.Path
        Category   = $cat
        SizeMB     = if ($i.Size -gt 0) { [math]::Round($i.Size/1MB, 2) } else { 0 }
        Backupable = $exp
        ManualLink = $link
        MimeType   = $i.MimeType
    }
}

# ---- console summary ----
Write-Host "`n=== Summary by type ===" -ForegroundColor Cyan
$report | Group-Object Category | Sort-Object Count -Descending |
    Select-Object @{n='Type';e={$_.Name}}, Count,
                  @{n='TotalMB';e={[math]::Round(($_.Group | Measure-Object SizeMB -Sum).Sum,1)}} |
    Format-Table -AutoSize

$manual = $report | Where-Object Backupable -like 'NO*'
if ($manual) {
    Write-Host "=== NEEDS MANUAL SAVE before wiping (script cannot export these) ===" -ForegroundColor Yellow
    $manual | Format-Table Path, Category, ManualLink -AutoSize -Wrap
} else {
    Write-Host "Nothing needs manual export - the backup script covers everything." -ForegroundColor Green
}

Write-Host "=== Full listing ===" -ForegroundColor Cyan
$report | Sort-Object Category, Path | Format-Table Path, Category, SizeMB, Backupable -AutoSize

if ($Csv) {
    $report | Export-Csv $Csv -NoTypeInformation -Encoding UTF8
    Write-Host "Saved CSV: $Csv" -ForegroundColor Green
}
