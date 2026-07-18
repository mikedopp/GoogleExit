# GoogleExit

Scripts to pull a Google account's data (Gmail + Drive/Docs) onto a local hard
drive, verify it, and then wipe it off Google — one account at a time. Built
because Google keeps shrinking storage tiers and charging more; each family
member's data goes onto their own drive.

**No credentials live in this repo.** `client_secrets.json`, OAuth tokens, the
downloaded tools, and all logs are gitignored. If you clone this fresh, follow
[One-time setup](#one-time-setup) to recreate them.

## The three scripts

| Script | What it does |
|---|---|
| `Invoke-GoogleExport.ps1` | Backs up one account: Gmail via GYB, Drive via rclone (Docs→.docx, Sheets→.xlsx, Slides→.pptx). Incremental — re-runs only fetch new items. |
| `Get-DriveInventory.ps1` | Read-only listing of everything in a Drive, flagging items the API **cannot** export (My Maps, Forms, Sites, Apps Script) with direct links to save them manually. Run this before wiping. |
| `Invoke-GoogleCleanup.ps1` | **DESTRUCTIVE.** Re-runs the backup, shows counts, requires typing the email address, then empties Drive (trash + empty trash) and permanently purges all Gmail. |

## How it works

- **Drive:** [rclone](https://rclone.org) with a per-account read-only remote
  (`gdrive-<name>`). Google-native docs are converted to Office formats so they
  open without Google. Deletion uses a separate read-write remote
  (`gdrive-<name>-rw`) created only when you run the cleanup — the backup
  remote physically cannot delete anything.
- **Gmail:** [GYB (Got Your Back)](https://github.com/GAM-team/got-your-back).
  Every message — received, sent, drafts, spam, trash — is saved as a raw
  `.eml` file with full headers, plus a SQLite index preserving labels. Mail
  flows directly Google → your disk through a Google Cloud project **you own**;
  no third-party server ever touches it.
- **Reading the archive later:** import the `.eml` files into Thunderbird
  (Local Folders) for full-text search, sort by sender/date, etc. The raw
  headers (timestamps, addresses, message-IDs) make it suitable for
  legal/records purposes.

## One-time setup (per PC)

GYB's automated `--action create-project` is **blocked by Google** now
("Access blocked: GYB has not completed Google verification"), so the project
is created manually. ~5 minutes, free, done once — every account reuses it.

1. [console.cloud.google.com](https://console.cloud.google.com) → sign in as
   your main account → New project (accept the Terms of Service if prompted).
2. **APIs & Services → Library** → search "Gmail API" → **Enable**.
3. **Google Auth Platform → Branding** (a.k.a. OAuth consent screen): any app
   name, your email, audience **External** → save. Leave publishing status as
   **Testing** — do not publish.
4. **Google Auth Platform → Audience → Test users → Add users**: add your own
   Gmail address AND every family member's address you'll ever back up.
   *(This list is what prevents 403 "access blocked" errors — see
   [Troubleshooting](#troubleshooting).)*
5. **Clients → Create client** → type **Desktop app** → Create → **download
   the JSON immediately** (Google won't show the secret again later).
6. Save the JSON as `tools\gyb\gyb\client_secrets.json` (run the export script
   once first so it downloads GYB and creates that folder).

## Per-account workflow

```powershell
# 1. Back up (first run: two browser sign-ins - SIGN IN AS THAT ACCOUNT)
.\Invoke-GoogleExport.ps1 -Email kid1@gmail.com -Dest E:\

# 2. See what the API could NOT back up (My Maps, Forms, ...)
.\Get-DriveInventory.ps1 -Email kid1@gmail.com -Csv E:\kid1-inventory.csv
#    -> manually save anything flagged (My Maps: ⋮ menu -> Export to KML/KMZ)

# 3. Google Photos: https://takeout.google.com signed in as that account
#    (no API for this - see Warnings), save the zips onto the same drive

# 4. Spot-check the backup! Open a few .eml files, open a few Drive files.

# 5. Wipe it off Google (asks you to type the email address to confirm)
.\Invoke-GoogleCleanup.ps1 -Email kid1@gmail.com -Dest E:\
#    Gmail only:  add -SkipDrive     Drive only:  add -SkipGmail
```

Output layout per account:

```
<Dest>\<email>\
    Drive\          all Drive files; Google docs as .docx/.xlsx/.pptx
    SharedWithMe\   only with -IncludeSharedWithMe
    Gmail\          GYB archive (.eml files + msg-db.sqlite index)
    logs\           transcripts + rclone logs for every run
```

## Adding a new user / kid

1. **Add their Gmail address to the test users list**: Google Cloud console →
   Google Auth Platform → **Audience** → Test users → **Add users**. Skip this
   and their sign-in dies with a 403.
2. Run the export with their email and their drive as `-Dest`.
3. When the browser opens (twice on first run — once for Drive, once for
   Gmail), **sign in as the kid's account**. If Chrome shows an account
   chooser with the whole family, pick carefully — choosing the wrong account
   backs up the wrong mailbox.
4. At "Google hasn't verified this app": **Advanced → Continue**. That's your
   own project; it's unverified because it's personal, not because it's shady.
5. GYB's first run per account asks which scopes to grant — the defaults
   (Gmail Full Access) are correct; full access is required for the eventual
   purge. Type `7` (Continue) at its menu.

Everything is stored per-account (separate folders, separate rclone remotes,
separate GYB tokens), so accounts can be done one at a time in any order.

## Warnings

- **The cleanup purge is not recoverable.** GYB's purge permanently deletes
  every message — it does not pass through trash. Verify the backup first;
  the script's counts are a sanity check, not a substitute for opening a few
  messages yourself.
- **One drive = one point of failure.** Once the data is off Google, that hard
  drive is the only copy. Make a second copy of anything irreplaceable.
- **Google Photos cannot be backed up by these scripts.** Google removed
  full-quality API access in 2025. Use [Takeout](https://takeout.google.com)
  per account (50 GB zip parts), then delete photos at photos.google.com.
  Photos storage is a separate bucket — wiping Drive/Gmail doesn't touch it.
- **My Maps / Forms / Sites / Apps Script don't export via API.** Run
  `Get-DriveInventory.ps1` before wiping — it flags them with direct links.
  (Silver lining: rclone's delete can't see them either, so they survive a
  Drive wipe untouched and cost ~0 bytes of quota.)
- **Old chat history** (Hangouts-era messages stored inside Gmail) isn't
  reliably exposed by the API — Takeout's "Chat" section if you care.
- **Gmail API daily quota:** a 15–20 GB mailbox may hit the per-user daily cap
  mid-backup. GYB just stops; re-run the next day and it resumes. Don't plan
  ten huge mailboxes in one afternoon.
- **rclone's shared client_id is being retired during 2026.** If rclone auth
  starts failing months from now, make your own client id:
  [rclone.org/drive](https://rclone.org/drive/#making-your-own-client-id).
- **The address keeps working after the purge.** Emptying an account doesn't
  close it — new mail still arrives. Re-run cleanup later or set up
  forwarding.
- **The Save As dialog eats downloads.** If Chrome is set to "ask where to
  save each file," console JSON downloads sit in a native dialog that's easy
  to miss.

## Troubleshooting

Every one of these was hit for real while building this.

| Symptom | Cause / Fix |
|---|---|
| `rclone is not recognized` right after winget installs it | PATH isn't refreshed in the current shell. The scripts search winget's package folder directly; for manual use, open a new terminal. |
| `gyb is not recognized` | GYB unzips one level deeper than expected: `tools\gyb\gyb\gyb.exe`. Use the full path (quoted, with `&` in PowerShell). |
| GYB: `ERROR: Please configure a project` / missing `client_secrets.json` | One-time setup not done, or the JSON isn't at `tools\gyb\gyb\client_secrets.json`. See [One-time setup](#one-time-setup). |
| `Access blocked: GYB has not completed Google verification` during `--action create-project` | Google blocks GYB's automated setup entirely. Create the project manually — that's why the setup section above exists. |
| **403 / access_denied** when an account signs in | That email isn't on the project's **test users** list (Audience page). Add it. This is not a propagation delay — waiting doesn't fix it. |
| "Google hasn't verified this app" warning | Normal for a personal project. Advanced → Continue. |
| Can't re-download the OAuth client JSON | Google only offers the secret at creation time now. On the client's page: **Add secret** → download the new JSON (max 2 secrets; delete the old one after switching). |
| Clicked Download JSON, no file appears | Chrome's "ask where to save" opened a native Save As dialog somewhere. Also check Chrome's actual download folder — it may not be `%USERPROFILE%\Downloads`. |
| rclone: `Skipping unexportable google document` | My Maps / Forms / etc. — the API can't export these at all. Inventory script lists them with manual-save links. |
| rclone: `This remote uses rclone's shared Google Drive client_id, which is being retired` | Informational through 2026. Make your own client id if auth breaks. |
| rclone finishes "with errors" | Usually individual files Google refuses to export (size caps, abuse flags). Check `logs\rclone-drive-*.log`; re-running retries just the failures. |
| GYB backup dies mid-run | Daily API quota, network, whatever — just re-run; it resumes from the SQLite index. |
| Storage meter unchanged after wiping | one.google.com/storage takes up to 24 h to update. Emptying Drive **trash** is what frees quota (the cleanup script does this via `rclone cleanup`). |
| Cleanup refuses to run | By design: no backup folder → refuses; no GYB database → refuses Gmail purge; typed email doesn't match → aborts. Fix the missing backup rather than bypassing the gate. |

## Restore / reading the archive

- **Browse & search mail:** Thunderbird → Local Folders → import the `.eml`
  files (ImportExportTools NG add-on makes bulk import easy). Full-text
  search, sort by sender/date/subject.
- **Put mail back into a Gmail account:** `gyb --email <acct> --action restore
  --local-folder <path>` restores messages *with labels* into any account you
  can sign into.
- **Drive files** are ordinary files — nothing to restore, just open them.
