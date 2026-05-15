---
title: "BenchVault Quickstart"
subtitle: "Back up LabArchives GOV notebooks and read them offline"
author: "BenchVault"
date: "May 15, 2026"
geometry: margin=0.75in
fontsize: 11pt
colorlinks: true
---

# BenchVault Quickstart

BenchVault is a desktop app for backing up LabArchives GOV electronic lab notebooks
and reading those backups later in a read-only viewer. It is designed for lab
records, experiment notes, protocols, tables, images, PDFs, sequence files,
instrument output, and other bench-research attachments.

![BenchVault read-only viewer](../assets/screenshots/benchvault-viewer.png){width=95%}

## What BenchVault Does

- Backs up every notebook that your LabArchives account is allowed to back up.
- Keeps the original LabArchives archive file for preservation.
- Verifies full-size original attachment files after backup by byte size.
- Seals each backup with SHA-256 checksums and warns if files change later.
- Creates a readable Markdown copy and search index for each backup.
- Lets you search backed-up notebooks with local fuzzy matching, or with
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
see a notebook but you are not the PI owner, BenchVault can list it but cannot
download its full-size backup archive.

Choose a backup folder that is easy to protect and easy to find. A good pattern
is to create a dedicated folder named `BenchVault_Backups` in a secure local or
approved institutional storage location.

## First Launch Setup

1. Open BenchVault.
2. Enter your LabArchives email address.
3. Enter your access ID and access key.
4. Choose the folder where routine backup copies should be stored.
5. Enter an OpenAI API key if you want natural-language notebook search.
6. Click `Connect`.
7. Complete the LabArchives authorization step in the browser.
8. Return to BenchVault after authorization is captured.

If browser authorization does not complete cleanly, paste the LabArchives auth
code into the setup screen and click `Use Auth Code`.

## Run a Manual Backup

1. Click `Backup All`.
2. Keep the app open while the backup is running.
3. Watch the status messages in the backup log.
4. When backup finishes, select a backup from the left pane.
5. Browse pages in the notebook tree.
6. Select a page to read its backed-up contents.

BenchVault may skip notebooks that are visible to you but not eligible for API backup
with your current permissions. This does not mean the backup system failed. It
means LabArchives did not grant backup rights for that notebook. At NIH/NICHD,
ask the lab chief or PI owner to run the backup for that notebook.

## Confirm Full-Size Originals

For each successful notebook backup, BenchVault verifies the original attachment
payloads. A successful backup means:

- The LabArchives `.7z` archive was saved.
- Each reported attachment has an `original` file in the extracted backup.
- Each original file has the same byte size reported by LabArchives.
- A checksum manifest was written for later auditing.
- An integrity seal was written so the viewer can detect later byte changes.

The manifest is named `original_files_manifest.json`. It includes relative file
paths, expected byte counts, actual byte counts, and SHA-256 checksums.

BenchVault also writes `integrity_manifest.json` for the whole backup run and records
a local seal in the ignored credentials folder. When you open a backup later,
the viewer re-checks protected files. If a file was changed, removed, or added,
BenchVault shows a warning before you rely on that copy. This is tamper-evidence for
local preservation; it is not a legal certification by itself.

## Supported Attachments

LabArchives can attach documents of any file type and format. BenchVault therefore
preserves and restores every original payload it finds in a full-size backup,
even when no inline preview is available.

The read-only viewer recognizes the same major LabArchives attachment families:

- Common browser images such as PNG, JPG, JPEG, GIF, WebP, and BMP.
- Text, tabular, structured, and sequence files such as TXT, CSV, TSV,
  Markdown, JSON, XML, FASTA, GenBank, EMBL, BED, VCF, GFF, and GTF.
- PDFs and Microsoft Office documents.
- Jupyter notebooks.
- SnapGene, Geneious, Sanger trace, and related molecular biology files.
- Chemical structure files such as CDX, CDXML, MOL, SDF, and SKC.
- Media files, archives, and other custom instrument exports.

BenchVault previews safe local formats inline, including common images, text-like
files, sequence text, chemical text files, and a Jupyter notebook summary.
Tool-specific formats such as Office files, PDFs, TIFF images, SnapGene files,
binary chemical drawings, media, and custom instrument exports are still
preserved, sealed, and restorable from the attachment card for inspection in the
appropriate local application. HTML and SVG attachments are shown as source text;
the viewer does not run embedded scripts.

## Search Backed-Up Notebooks

![Natural-language notebook search](../assets/screenshots/benchvault-ai-search.png){width=80%}

Use the search field above the notebook viewer to ask about backed-up content.
BenchVault always creates a local readable copy first, then searches that copy.

Without an OpenAI API key, or if the OpenAI request fails, search uses local
fuzzy matching and shows the best matching pages. With an OpenAI API key, BenchVault
sends the best matching excerpts to OpenAI and returns a concise answer with
page citations. The OpenAI key is stored locally in the ignored credentials
folder.

Useful searches include:

- `Which pages mention zebrafish hypoxia imaging?`
- `Find attachment records for qPCR or RNA-seq runs.`
- `What did the PI reviewer ask us to repeat?`
- `Show pages about freezer transfer or chain of custody.`

## Set Automatic Backups

![Automatic backup schedule](../assets/screenshots/benchvault-schedule.png){width=80%}

1. Click the schedule button in the toolbar.
2. Turn `Enabled` on.
3. Choose `Daily` or `Weekly`.
4. Pick the time of day.
5. Confirm the backup folder.
6. Click `Save`.

Scheduled backups run while BenchVault is open. If the app is closed, a scheduled
backup will not run until app-level background scheduling is added for your
platform.

## Backup Folder Structure

BenchVault organizes routine copies inside the folder you choose:

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
            integrity_manifest.json
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
- Watch the integrity banner at the top of the viewer before relying on a
  backup copy.

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

`Original attachment verification failed`: BenchVault did not find every full-size
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
