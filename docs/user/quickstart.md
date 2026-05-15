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
- Uses a production read-only LabArchives allowlist for login, user-access
  lookup, and notebook backup download only.
- Runs a Backup Center preflight before backup starts.
- Keeps the original LabArchives archive file for preservation.
- Verifies full-size original attachment files after backup by byte size.
- Seals each backup with SHA-256 checksums and warns if files change later.
- Creates a readable Markdown copy and search index for each backup.
- Lets you search backed-up notebooks with local search, or with
  natural-language answers when you add an OpenAI API key.
- Lets you schedule routine backups while the app is open.
- Stores credentials and backups locally, not in GitHub.

> BenchVault is for backup and offline viewing. The production app does not add,
> update, delete, upload, or write content back to the original LabArchives
> notebook.

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

> At NIH and NICHD, full-size LabArchives backup is owner-only. A visible notebook
> is not necessarily a notebook your account can download as a full preservation
> archive.

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

1. Review the Notebook Protection health strip.
2. Open `Details` if any item says `Blocked` or `Review`.
3. Resolve blocking checks before backup.
4. Click `Back Up Eligible Notebooks`.
5. Keep the app open while the backup is running.
6. Watch the status messages in the backup log.
7. When backup finishes, select a backup from the left pane.
8. Browse pages in the notebook tree.
9. Select a page to read its backed-up contents.

The preflight checks local readiness before backup starts. It covers local
credentials, notebook list, backup folder writability, available storage, archive
extractor availability, the read-only LabArchives API guardrail, OpenAI search
configuration, and schedule state. A blocking preflight check prevents backup
from starting until it is resolved.

After each run, BenchVault writes a local run manifest with per-notebook
outcomes, classified skip reasons, successful backup records, and the run log.
The Protected Notebooks pane shows the latest run summary, persistent Notebook
Protection cards, and the local backup copies available for reading. Each notebook card combines
the latest run outcome with prior local backups, so a skipped notebook can still
show whether an older protected copy exists. Open `Details` in the latest-run
banner to review every notebook outcome, suggested next action, and run-log
line.

If a run has skipped notebooks that are likely fixable, such as network,
storage, extraction, verification, or authorization problems, the latest-run
banner shows a retry action. Owner-rights skips are not retried because only the
notebook owner can download the full-size backup.

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
a local seal in the ignored credentials folder. The local seal ledger is chained,
so removing or rewriting an earlier seal makes later seals fail local
corroboration. When you open a backup later, the viewer re-checks protected
files. If a file was changed, removed, or added, BenchVault blocks the normal
reader and shows `Local copy not verified` until you review the details and
deliberately choose `Open Unverified Copy`. This is tamper-evidence for local
preservation; it is not a legal certification by itself.

The viewer treats backup metadata paths as untrusted. It rejects absolute paths,
drive-letter paths, UNC-style paths, `..` traversal, and files that resolve
outside the backup folder before previewing or saving an original attachment.

> Tamper-evidence depends on protecting the backup folder after it is written.
> BenchVault can warn when sealed files change, but it does not replace formal
> records policy, chain-of-custody review, or institutional legal guidance.

## Export An Audit Summary

When a backup is selected, the Notebook Protection health strip includes an
`Export Audit` action.
BenchVault writes three local sidecars under the selected backup run's `audit/`
folder:

- `backup_audit_summary.md`: human-readable backup and integrity summary.
- `backup_audit_summary.json`: machine-readable backup, integrity, and export
  metadata, including compact archive diagnostics such as source layout,
  page/part counts, attachment counts, thumbnail counts, and part-type counts.
- `integrity_files.csv`: protected file paths, byte counts, SHA-256 hashes, and
  backup-time modification timestamps.
- `external_hash_anchor.txt`: a compact manifest-hash record that can be placed
  in an institutional records system, WORM storage, or another append-only
  location.

The audit export is derived from the local backup and integrity manifest. It is
useful for review packets and internal records conversations, but it is still
tamper-evidence rather than legal certification by itself.

## Supported Attachments

LabArchives can attach documents of any file type and format. BenchVault
therefore preserves every original file it finds in a full-size backup and can
save it locally even when no inline preview is available.

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
preserved, sealed, and available from the attachment card for inspection in the
appropriate local application. HTML and SVG attachments are shown as source text;
the viewer does not run embedded scripts.

Attachment cards show whether the original file was preserved in the backup,
whether the format is usually viewable in LabArchives, the reported byte size,
and the relative path of the preserved original file. Use the `Save Original`
button on the card to copy the original file into a folder you choose.

## Search Backed-Up Notebooks

![Natural-language notebook search](../assets/screenshots/benchvault-ai-search.png){width=80%}

Use the search field above the notebook viewer to ask about backed-up content.
BenchVault always creates a local readable copy first, then searches that copy.
Use the search controls to narrow results to page text, attachments, comments,
exact phrases, or verified backups only.

Without an OpenAI API key, or if the OpenAI request fails, search uses local
BM25-style relevance, phrase boosts, typo-tolerant matching, and character
n-grams to show the best matching pages. With an OpenAI API key, BenchVault
sends the best matching excerpts to OpenAI and returns a concise answer with
page citations. On macOS app launches, the OpenAI key is stored in macOS
Keychain when available; non-secret search settings remain in the ignored local
setup folder.

> Credentials, OpenAI keys, notebook IDs, access XML, source PDFs, and raw backup
> archives should remain local-only. Public GitHub files should contain only
> examples or placeholders.

On macOS, BenchVault uses Keychain for newly saved LabArchives access
credentials and OpenAI API keys when available. Setup metadata, UID records,
notebook indexes, schedules, and integrity ledgers remain local-only files.

Useful searches include:

- `Which pages mention zebrafish hypoxia imaging?`
- `Find attachment records for qPCR or RNA-seq runs.`
- `What did the PI reviewer ask us to repeat?`
- `Show pages about freezer transfer or chain of custody.`

## Set Auto Backup While App Is Open

![Auto backup schedule](../assets/screenshots/benchvault-schedule.png){width=80%}

1. Click the schedule button in the toolbar.
2. Turn `Run auto backup while app is open` on.
3. Choose `Daily` or `Weekly`.
4. Pick the time of day.
5. Confirm the backup folder.
6. Click `Save`.

Scheduled backups run while BenchVault is open. If the app is closed, a
scheduled backup will not run until app-level background scheduling is added for
your platform.

## Known Limitations

BenchVault is meant for backup and offline viewing. It does not edit
LabArchives, write records back into LabArchives, back up external systems
linked from notebook pages, or replace institutional records policy.

Current practical limits:

- Full-size backup is limited by LabArchives owner permissions.
- Auto backups run only while the app is open.
- Integrity checks are tamper-evidence, not true immutability or legal
  certification.
- The viewer preserves more formats than it previews inline. Office files, PDFs,
  TIFF images, SnapGene files, media, archives, and proprietary instrument files
  may need to be saved and opened in another local application.
- Search does not read inside most binary attachments. OpenAI search sends only
  selected excerpts when an OpenAI key is configured; otherwise BenchVault uses
  local search.
- Credentials and backups are local files protected by local machine controls;
  they are not stored in a built-in encrypted vault.
- macOS is the primary tested platform. Windows and iPad support are scaffolded
  but still need platform-specific validation.

The full limitations list is maintained in `docs/implementation_limitations.md`.

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
- Check each notebook's `Notebook Protection` card for latest run status, owner
  action, prior local copies, and original-attachment verification.
- Use the page breadcrumb and outline to orient yourself inside long notebooks.
- Review page titles and entries.
- Read text entries, rich text, and headings.
- Check attachment names, types, sizes, and preservation evidence chips.
- Click the `Save Original` button on an attachment card to copy the
  backed-up original file into a folder you choose.
- Open the backup folder when you need to inspect the preservation archive.
- Watch the Notebook Protection health strip before relying on a backup copy.
- Open the integrity details button to review the manifest path, local seal
  state, checked file count, checked byte count, manifest hash, and any changed,
  missing, or unexpected files.
- Click `Export Audit` in the health strip to export a local Markdown summary,
  machine-readable JSON, integrity-file CSV, and external hash anchor for the
  selected backup.

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

`No protected notebook backups yet`: Click `Back Up Eligible Notebooks`, or
check that the backup folder is available.

## Quick Checklist

- Connect credentials.
- Choose backup folder.
- Click `Back Up Eligible Notebooks`.
- Confirm the backup appears in the viewer.
- Check that original attachment verification passed.
- Enable routine backups.
