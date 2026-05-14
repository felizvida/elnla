---
title: "ELNLA Quickstart for Biologists"
subtitle: "Back up LabArchives notebooks and read them offline"
author: "ELNLA"
date: "May 14, 2026"
geometry: margin=0.75in
fontsize: 11pt
colorlinks: true
---

# ELNLA Quickstart for Biologists

ELNLA is a desktop app for backing up LabArchives GOV electronic lab notebooks
and reading those backups later in a read-only viewer. It is designed for lab
records, experiment notes, protocols, tables, images, PDFs, sequence files,
instrument output, and other bench-research attachments.

## What ELNLA Does

- Backs up every notebook that your LabArchives account is allowed to back up.
- Keeps the original LabArchives archive file for preservation.
- Verifies full-size original attachment files after backup.
- Creates a readable local copy for browsing pages and entries.
- Lets you schedule routine backups while the app is open.
- Stores credentials and backups locally, not in GitHub.

## Before You Start

You need:

- Your LabArchives GOV email address.
- Your LabArchives API access ID.
- Your LabArchives API access key.
- A local folder where routine backup copies should be saved.

At NIH and NICHD, lab notebook ownership is restricted to lab chiefs, also known
as PIs. The LabArchives full-size notebook backup API is owner-only. If you can
see a notebook but you are not the PI owner, ELNLA can list it but cannot
download its full-size backup archive.

Choose a backup folder that is easy to protect and easy to find. A good pattern
is to create a dedicated folder named `ELNLA_Backups` in a secure local or
approved institutional storage location.

## First Launch Setup

1. Open ELNLA.
2. Enter your LabArchives email address.
3. Enter your access ID and access key.
4. Choose the folder where routine backup copies should be stored.
5. Click `Connect`.
6. Complete the LabArchives authorization step in the browser.
7. Return to ELNLA after authorization is captured.

If browser authorization does not complete cleanly, paste the LabArchives auth
code into the setup screen and click `Use Auth Code`.

## Run a Manual Backup

1. Click `Backup All`.
2. Keep the app open while the backup is running.
3. Watch the status messages in the backup log.
4. When backup finishes, select a backup from the left pane.
5. Browse pages in the notebook tree.
6. Select a page to read its backed-up contents.

ELNLA may skip notebooks that are visible to you but not eligible for API backup
with your current permissions. This does not mean the backup system failed. It
means LabArchives did not grant backup rights for that notebook. At NIH/NICHD,
ask the lab chief or PI owner to run the backup for that notebook.

## Confirm Full-Size Originals

For each successful notebook backup, ELNLA verifies the original attachment
payloads. A successful backup means:

- The LabArchives `.7z` archive was saved.
- Each reported attachment has an `original` file in the extracted backup.
- Each original file has the same byte size reported by LabArchives.
- A checksum manifest was written for later auditing.

The manifest is named `original_files_manifest.json`. It includes relative file
paths, expected byte counts, actual byte counts, and SHA-256 checksums.

## Set Automatic Backups

1. Click the schedule button in the toolbar.
2. Turn `Enabled` on.
3. Choose `Daily` or `Weekly`.
4. Pick the time of day.
5. Confirm the backup folder.
6. Click `Save`.

Scheduled backups run while ELNLA is open. If the app is closed, a scheduled
backup will not run until app-level background scheduling is added for your
platform.

## Backup Folder Structure

ELNLA organizes routine copies inside the folder you choose:

```text
notebooks/
  notebook_name/
    year/
      month/
        day/
          run_timestamp/
            notebook.7z
            extracted/
            render_notebook.json
            original_files_manifest.json
            backup_record.json
runs/
  year/
    month/
      day/
        run_timestamp.json
```

This structure keeps each notebook separated and keeps every backup run
date-stamped. The paths saved in records and manifests are relative to the
backup folder.

## Read-Only Viewer

The viewer is for checking and reading backed-up records. It does not edit
LabArchives and it does not write changes back to LabArchives.

Use the viewer to:

- Confirm a notebook was backed up.
- Review page titles and entries.
- Read text entries, rich text, and headings.
- Check attachment names, types, and sizes.
- Open the backup folder when you need the original saved files.

## Good Lab Practice

- Run a manual backup after important notebook updates.
- Keep routine backup scheduling enabled on the computer used for records work.
- Periodically check that recent backups appear in the viewer.
- Keep the backup folder in a protected location.
- Do not email or commit credential files, user access XML, notebook IDs, or raw
  backup archives.
- Treat the `.7z` archive and `original_files_manifest.json` as preservation
  records.

## Troubleshooting

`Setup needed`: Connect LabArchives credentials again from the setup screen.

`Skipped notebook`: Your account can see the notebook, but LabArchives did not
grant API backup rights for it. At NIH/NICHD, full-size backup is owner-only,
and the notebook owner should be the lab chief or PI.

`Original attachment verification failed`: ELNLA did not find every full-size
original attachment or the byte sizes did not match. Run backup again. If it
still fails, keep the failed run for review and contact the project maintainer.

`No local backups yet`: Click `Backup All`, or check that the backup folder is
available.

## Quick Checklist

- Connect credentials.
- Choose backup folder.
- Click `Backup All`.
- Confirm the backup appears in the viewer.
- Check that original attachment verification passed.
- Enable routine backups.
