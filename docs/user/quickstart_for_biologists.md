---
title: "ELNLA Quickstart for Biologists"
subtitle: "Back up LabArchives GOV notebooks and read them offline"
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

![ELNLA read-only viewer](../assets/screenshots/elnla-viewer.png){width=95%}

## What ELNLA Does

- Backs up every notebook that your LabArchives account is allowed to back up.
- Keeps the original LabArchives archive file for preservation.
- Verifies full-size original attachment files after backup by byte size.
- Creates a readable Markdown copy and search index for each backup.
- Lets you search backed-up notebooks with local keyword matching, or with
  natural-language answers when you add an OpenAI API key.
- Lets you schedule routine backups while the app is open.
- Stores credentials and backups locally, not in GitHub.

## Before You Start

You need:

- Your LabArchives GOV email address.
- Your LabArchives API access ID.
- Your LabArchives API access key.
- A local folder where routine backup copies should be saved.
- An OpenAI API key if you want natural-language notebook search.

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
5. Enter an OpenAI API key if you want natural-language notebook search.
6. Click `Connect`.
7. Complete the LabArchives authorization step in the browser.
8. Return to ELNLA after authorization is captured.

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

## Search Backed-Up Notebooks

Use the search field above the notebook viewer to ask about backed-up content.
ELNLA always creates a local readable copy first, then searches that copy.

Without an OpenAI API key, search uses local keyword matching and shows the best
matching pages. With an OpenAI API key, ELNLA sends the best matching excerpts
to OpenAI and returns a concise answer with page citations. The OpenAI key is
stored locally in the ignored credentials folder.

Useful searches include:

- `Which pages mention zebrafish hypoxia imaging?`
- `Find attachment records for qPCR or RNA-seq runs.`
- `What did the PI reviewer ask us to repeat?`
- `Show pages about freezer transfer or chain of custody.`

## Set Automatic Backups

![Automatic backup schedule](../assets/screenshots/elnla-schedule.png){width=80%}

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
            readable/
              notebook.md
              search_chunks.jsonl
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
- Click the download button on an attachment card to restore a copy of the
  backed-up original file into a folder you choose.
- Open the backup folder when you need to inspect the preservation archive.

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
