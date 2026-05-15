# BenchVault Trust, Safety, And Correctness Model

Last reviewed: May 15, 2026.

This document explains how BenchVault works, what evidence it creates, how it
checks backup correctness, and how it avoids changing the original LabArchives
notebooks. It is written for maintainers, lab leadership, IT/security review,
and anyone deciding how much confidence to place in a BenchVault backup.

## Plain-English Summary

BenchVault is a local backup and read-only viewer for LabArchives GOV notebooks.
It downloads the full LabArchives backup archive, verifies reported original
attachment payloads, creates safe local viewing/search sidecars, and seals the
backup with SHA-256 hashes so later byte changes are visible before review.

The app is designed to answer three questions:

- Did LabArchives return a full backup archive for this notebook?
- Did the archive contain the original attachment payloads that LabArchives
  reported?
- Has any protected local backup file changed since BenchVault sealed it?

BenchVault provides tamper-evidence, not absolute immutability. It can warn when
a sealed local backup changes. It cannot stop a person, malware process, storage
administrator, or compromised operating system from modifying files on a writable
filesystem. Stronger evidence requires storing exported hashes or backup copies
in an external append-only or WORM-controlled system.

## Main Components

- `lib/src/labarchives_client.dart`: typed LabArchives GOV client. Production
  code is limited to read-only operations.
- `lib/src/backup_service.dart`: setup, preflight checks, download, extraction,
  verification, readable sidecar generation, integrity sealing, audit export,
  and attachment restore.
- `lib/src/backup_parser.dart`: parses LabArchives JSON backup tables, or a
  SQLite backup layout when JSON tables are absent and `sqlite3` is available.
- `lib/src/readable_notebook_exporter.dart`: creates Markdown and JSONL search
  sidecars from the parsed backup.
- `lib/main.dart`: macOS-first Flutter interface for setup, backup, offline
  viewing, integrity warnings, attachment restore, audit export, and search.
- `test/read_only_contract_test.dart`: regression tests that fail if production
  LabArchives code introduces mutable endpoints.
- `test/backup_service_settings_test.dart` and `test/backup_parser_test.dart`:
  regression tests for settings, parsing, search, restore, audit export, and
  integrity behavior.

## Backup Flow

For each selected notebook, BenchVault follows this sequence:

1. Run preflight checks for local credentials, notebook list, backup folder
   writability, disk/storage availability, archive extraction tools, read-only
   API guardrails, search settings, and schedule state.
2. Request the LabArchives GOV notebook backup with `json=true`.
3. Download the archive into a temporary `.part` file and move it to
   `notebook.7z` only after the HTTP response completes.
4. Extract the archive into an `extracted/` folder.
5. Parse notebook structure from LabArchives JSON tables, or from
   `notebook/db.sqlite3` when compatible.
6. Locate each reported original attachment payload and compare its actual byte
   count to the LabArchives-reported attachment size.
7. Write `original_files_manifest.json` with relative paths, byte counts, and
   SHA-256 hashes for verified original payloads.
8. Write `render_notebook.json`, the safe local representation used by the
   read-only viewer.
9. Write readable/search sidecars under `readable/`.
10. Write `backup_record.json`.
11. Seal the backup with `integrity_manifest.json`.
12. Append the integrity manifest hash to the local ignored integrity ledger.
13. Write a run manifest under `runs/` with per-notebook status, timing, log
    lines, skip reasons, retry metadata, and links to successful backup records.

If original attachment verification fails, BenchVault treats the notebook backup
as failed and removes that failed per-notebook run folder. This avoids presenting
an incomplete archive as a successful preservation copy.

## How Backup Correctness Is Checked

BenchVault checks correctness in several layers.

### Full-Size Archive Request

The production backup request uses LabArchives `notebook_backup` with
`json=true`. It deliberately does not pass `no_attachments=true`, because that
would create a lighter archive but break the preservation requirement for
full-size original payloads.

### Atomic Download Completion

The archive is streamed to `notebook.7z.part` first. Only after the response
stream finishes successfully does BenchVault move it to `notebook.7z`. This
reduces the risk that an interrupted download is mistaken for a complete backup.

This does not make downloads resumable. If the connection fails, the notebook
must be backed up again.

### Archive Extraction And Layout Parsing

BenchVault keeps the original `.7z` archive as the preservation reference and
extracts a local copy for parsing. JSON backup tables are the primary parser
path. If JSON tables are absent but a compatible `notebook/db.sqlite3` exists,
BenchVault can reconstruct tree nodes, entry parts, attachment version metadata,
and originals from SQLite.

The viewer and search sidecars are derived from the backup. They are convenient
local reading/search formats, not replacements for the original archive.

### Original Attachment Verification

For each LabArchives entry part with attachment metadata, BenchVault tries to
find the corresponding original payload under the extracted attachment tree. It
uses attachment version metadata when available and falls back to searching
inside the part's attachment directory.

For every expected original payload, BenchVault records:

- relative path from the backup root,
- expected byte count,
- actual byte count,
- SHA-256 hash,
- attachment part identifier,
- attachment name,
- original version when known.

A successful notebook backup requires expected originals to be present and byte
counts to match.

### Run Manifests And Failure Classification

Each run records a per-notebook outcome. Successful notebooks and skipped
notebooks can coexist in the same run. A skipped notebook does not hide prior
successful copies.

Common failures are classified into user-visible categories such as owner-rights,
authorization, storage, extraction, verification, network, setup, and unknown.
Eligible skipped notebooks can be retried from the latest run. Owner-rights
skips are not treated as retryable because retrying cannot make a non-owner
account eligible for full-size backup.

## How Tamper-Evidence Works

After a successful backup has been downloaded, extracted, parsed, verified, and
indexed, BenchVault creates `integrity_manifest.json`.

The integrity manifest records:

- the backup identifier,
- notebook name,
- backup creation time,
- protected file count,
- protected byte count,
- SHA-256 hashes for protected files,
- relative paths for protected files,
- a note explaining that this is tamper-evidence, not legal certification.

Protected files include the original archive, extracted payloads, render JSON,
readable/search sidecars, original attachment manifest, and backup record.
BenchVault excludes `integrity_manifest.json` itself and excludes `audit/`
exports so that creating an audit packet later does not make a sealed backup
appear modified.

BenchVault then appends the manifest hash to an ignored local integrity ledger.
When a user opens a backup later, BenchVault verifies:

- the integrity manifest still exists,
- the current manifest hash matches the local ledger entry,
- the local ledger chain is intact through that entry,
- every protected file still exists,
- every protected file still has the expected SHA-256 hash,
- no unexpected protected-file additions are present.

If a file is changed, missing, or unexpectedly added, the viewer shows a warning
before the user relies on the backup. The integrity details show the affected
relative file paths.

Backup metadata paths are treated as untrusted input. The viewer and attachment
restore paths reject absolute paths, drive-letter paths, UNC-style paths, and
`..` traversal before opening local files. Existing local files must also
resolve inside the configured backup folder, so symlink targets outside the
backup folder are rejected. Legacy records may point under `backups/`, but
arbitrary repository files and sibling folders are not accepted as backup
payloads.

## What This Does And Does Not Guarantee

BenchVault can detect later changes to protected backup files as long as the
integrity manifest and local ledger have not both been maliciously rewritten.
This is useful for routine accidental-change detection, local audit review, and
evidence conversations.

BenchVault cannot, by itself, prove originality against an attacker who can
modify all local files, alter the local ledger, replace the app, or control the
operating system. For stronger evidence, users should export the hash anchor or
audit packet and store it outside the backup folder in an institutional records
system, WORM storage, S3 Object Lock bucket, trusted timestamp service, or other
append-only system.

The strongest current local practice is:

1. Back up with BenchVault.
2. Open the backup and confirm integrity is verified.
3. Export the audit packet.
4. Store `external_hash_anchor.txt`, or at minimum the manifest SHA-256, in an
   external controlled record.
5. Protect the backup folder with operating-system permissions, full-disk
   encryption, institutional storage controls, and access logging where
   available.

## How BenchVault Avoids Writing To Original Notebooks

BenchVault's production LabArchives access is intentionally narrow.

The production client allowlists only:

- browser login URL generation,
- user-access lookup,
- notebook backup download.

The LabArchives client rejects endpoint names with mutable prefixes such as
`add_`, `create_`, `delete_`, `insert_`, `move_`, `patch_`, `post_`, `put_`,
`remove_`, `replace_`, `restore_`, `share_`, `update_`, and `upload_`.

The backup endpoint also rejects unexpected parameters. This matters because
even a read endpoint can be weakened by parameters that change preservation
behavior.

The app never restores data back into LabArchives. In BenchVault, "restore
attachment" means copying a backed-up original payload to a user-selected local
folder. The destination filename is sanitized and made unique to avoid
overwriting an existing local file.

The repository contains one write-capable script:

- `scripts/labarchives_seed_bio_test_notebook.py`

That script is only for synthetic testing notebooks. It is not part of the
production app, is documented as dangerous, and is locked behind explicit opt-in
environment guards. The production read-only tests are intended to catch any
accidental write capability added to the app or production client.

Important remaining boundary: BenchVault cannot stop a user from manually
editing notebooks in the LabArchives web UI after a browser login page opens.
The guarantee here is about BenchVault production code, not every possible user
action in a browser.

## Local Data And Secret Handling

BenchVault keeps sensitive operational files out of Git. Credentials, UID files,
user-access XML, notebook indexes, backup archives, integrity ledgers, OpenAI
keys, source PDFs, and local backups belong in ignored local paths or platform
secret storage.

On macOS app launches, BenchVault prefers macOS Keychain for LabArchives access
ID/access key and OpenAI API keys. Non-secret setup metadata, schedules, notebook
indexes, and integrity ledgers remain local. Non-macOS secure stores are still
future work.

Public repository docs and code should use project-relative paths only. They
must not include local absolute paths, credentials, notebook IDs, raw backup
archives, or source PDFs.

## Audit Export

The integrity banner can export a local audit packet under the selected backup
run's `audit/` folder:

- `backup_audit_summary.md`,
- `backup_audit_summary.json`,
- `integrity_files.csv`,
- `external_hash_anchor.txt`.

The audit JSON and Markdown include compact archive diagnostics such as source
layout, page counts, entry-part counts, attachment counts, thumbnail counts,
attachment version metadata counts, and part-type counts. These diagnostics help
support review without exposing raw SQL tables in the normal viewer.

Audit exports are sidecars. They are useful for review and for moving the
manifest hash into an external record, but they are not themselves a legal
certification.

## User-Facing Safety Signals

BenchVault surfaces safety status in the UI:

- preflight panel before backup,
- read-only contract banner,
- latest run summary and notebook status cards,
- per-notebook skipped/success outcomes,
- owner-rights explanations for NIH/NICHD context,
- integrity banner before viewing a selected backup,
- integrity details for changed, missing, or unexpected files,
- audit export action,
- attachment cards showing preservation evidence and restore behavior.

The goal is that a reviewer should not need to inspect raw logs to know whether
a backup is usable.

## Operational Recommendations

For routine use:

- Run BenchVault only from a trusted local account.
- Choose a backup folder outside the repository.
- Protect the backup folder with disk encryption and institutional access
  controls.
- Keep the original `.7z`, `original_files_manifest.json`,
  `integrity_manifest.json`, and `backup_record.json` together.
- Export an audit packet for important backups.
- Store the external hash anchor in a system outside the writable backup folder.
- Re-run setup when notebook ownership or access changes.
- Treat owner-rights failures as ownership/permission issues, not app failures.
- Keep raw backup archives and credentials out of Git.

For release review:

- Run automated tests.
- Run the read-only endpoint tests.
- Run secret and local-path scans.
- Verify demo screenshots use synthetic data only.
- Verify `ref/` and any source PDFs remain ignored and untracked.
- Keep limitations documentation current.

## Current Limitations Worth Remembering

- Tamper-evidence is not immutability.
- Local integrity evidence is weaker than externally anchored evidence.
- Windows and iPad support are scaffolded but not validated as release targets.
- The macOS release is not yet signed or notarized.
- SQLite backup parsing depends on a local `sqlite3` command and compatible
  LabArchives schema.
- Binary attachment contents are preserved but not generally text-indexed.
- BenchVault does not back up external systems linked from notebook pages.
- BenchVault is not a LabArchives editor, migration tool, legal certification
  system, or institutional records-management replacement.
