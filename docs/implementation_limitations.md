# BenchVault Implementation Limitations

Last reviewed: May 15, 2026.

This document is intentionally blunt. BenchVault is designed for LabArchives GOV
backup and offline viewing, but the current implementation has clear boundaries
that users and maintainers should understand before relying on it for records
work.

## Scope

- BenchVault is a backup and offline-viewing app. It is not a LabArchives
  editor, synchronization client, migration tool, or disaster-recovery restore
  system.
- The production app does not write restored data back to LabArchives. Restoring
  an attachment means copying a backed-up original payload to a local folder.
- The app currently targets LabArchives GOV at `api.labarchives-gov.com`. It is
  not configured for other LabArchives regions or deployments.
- The app does not implement LabArchives Scheduler or Inventory backup.
- The app does not back up external systems referenced by links inside a
  notebook, such as cloud storage folders, institutional data repositories, LIMS
  records, imaging databases, or sequence archives. It preserves the link text
  and URL when those appear in backed-up notebook content.

## Read-Only Safety

- Production LabArchives access is allowlisted to browser login, user-access
  lookup, and full notebook backup download. This reduces accidental-write risk,
  but it is a software guardrail rather than a mathematical proof about every
  future change.
- The repository includes one intentionally write-capable helper,
  `scripts/labarchives_seed_bio_test_notebook.py`, for synthetic integration
  notebooks. It is locked behind an environment guard and an explicit
  acknowledgement flag, but it must still be treated as a dangerous test tool.
- The app cannot prevent a user from taking unrelated actions in the LabArchives
  web UI after the browser login page opens.
- The read-only contract is enforced by code review, tests, endpoint allowlists,
  and documentation. It does not replace network-level controls, institutional
  policy, or LabArchives-side permissions.

## Permissions And Notebook Eligibility

- Full-size LabArchives notebook backup is owner-only in the NIH/NICHD context.
  A notebook that is visible to an account may still fail backup if the account
  is not the owner.
- BenchVault can report skipped notebooks, but it cannot grant backup rights or
  determine institutional ownership beyond what the LabArchives API returns.
- The notebook list is captured during setup from the LabArchives user-access
  response. If ownership or access changes later, setup must be run again before
  the local list reflects the change.

## Backup Coverage

- Backup depends on LabArchives `notebook_backup` with `json=true`. If
  LabArchives changes the archive layout or omits data from that export,
  BenchVault can only process what the archive contains.
- BenchVault keeps the `.7z` archive and derived local files. It does not
  currently create a second offsite copy, WORM copy, cloud-object-lock copy, or
  institutional records-management deposit.
- The app verifies original attachment files that are listed in
  `entry_parts.json` with attachment metadata. It cannot verify payloads that
  LabArchives does not list or does not include in the backup archive.
- A known LabArchives behavior observed during testing is that no-extension
  attachment names were accepted by LabArchives but omitted from the backup
  archive. BenchVault treats missing originals as a backup failure.
- Failed per-notebook backup attempts are removed from the backup folder after
  failure. The user sees the skip reason in the log, but partial failed payloads
  are not kept for later forensic review.
- Backups are full-run copies, not incremental or resumable downloads. Large
  notebooks may take time and storage, and an interrupted backup must be run
  again.
- The app does not yet implement retention rules, deduplication, quota warnings,
  checksum export to external media, or automatic offsite replication.

## Archive Extraction

- The implementation relies on local command-line extractors and tries `bsdtar`,
  `tar`, then `7z`. If none of those can read the LabArchives `.7z` archive on
  the current platform, backup parsing will fail after download.
- JSON backup tables are the primary parser path. If JSON tables are absent but
  `notebook/db.sqlite3` is present, BenchVault can parse a SQLite layout through
  the local `sqlite3` command. If `sqlite3` is unavailable or the schema differs
  materially, SQLite parsing will fail with a compatibility message.
- Extraction errors are reported as backup failures. BenchVault does not repair
  corrupt archives.
- The original `.7z` archive is retained for successful backups, so unsupported
  viewer parsing does not necessarily mean the preservation archive is missing.

## Read-Only Viewer

- The viewer is optimized for offline review, not pixel-perfect reproduction of
  the LabArchives web UI.
- Rich text is converted to safe readable text. Formatting such as complex
  tables, colors, embedded styling, layout, and some special characters may be
  simplified.
- HTML anchors are preserved as `label (URL)` text, but active HTML behavior is
  not run.
- HTML and SVG attachments are shown as source text for safety.
- The parser currently labels known part types for headings, rich text, plain
  text, and attachments. Unknown entry-part types are preserved as generic entry
  parts when possible, but they may not receive specialized rendering.
- Empty pages or unusual LabArchives tree structures may not appear exactly as
  they do in LabArchives because the viewer infers readable pages from backed-up
  entry parts.
- The viewer does not currently expose every possible LabArchives audit trail,
  revision history, page-signature state, widget behavior, or permission detail
  that may exist in the source system.
- Page breadcrumbs, counts, and outlines are generated from the backed-up tree
  and entry-part order. They are navigation aids, not a replacement for
  LabArchives' complete provenance model.

## Attachments

- BenchVault preserves and restores original payloads when the full-size backup
  archive includes them, and records attachment version and thumbnail paths when
  the backup exposes them. It previews only safe local formats inline.
- Office documents, PDFs, TIFF images, SnapGene/Geneious files, binary chemical
  drawings, media, archives, and custom instrument exports are recognized but
  generally opened outside BenchVault after local restore.
- The app does not parse text out of Office documents, PDFs, images, SnapGene
  binaries, media, compressed archives, or proprietary instrument files for
  search.
- Jupyter notebooks receive a lightweight cell summary, not a full notebook
  execution environment.
- The viewer does not execute scripts, macros, embedded HTML, remote resources,
  notebooks, or instrument workflows from backed-up attachments.
- Restored attachment filenames are sanitized and made unique in the selected
  destination folder, so the restored local filename may differ slightly from
  the original path when needed to avoid overwriting.

## Search

- Local fallback search is fuzzy lexical search. It uses term relevance, phrase
  boosts, typo-tolerant matching, and character n-gram similarity, but it is not
  a full semantic vector-search system.
- OpenAI-powered search sends selected notebook excerpts and attachment metadata
  to OpenAI when an API key is configured. Users should not enable it for
  content that policy forbids sending to external services.
- The OpenAI answer is an aid for finding relevant backed-up pages. It is not a
  scientific, legal, or records-management determination.
- Search is built from the readable sidecar. Binary attachment contents that are
  not converted into text are not searched beyond their names, paths, sizes, and
  metadata.
- Search filters narrow the local corpus by page text, attachment metadata,
  comment-bearing pages, exact phrase, or verified backup state. Comment search
  currently narrows to pages with comments, then searches the page excerpt.
- Search results depend on the quality of the extracted text. Any text lost
  during LabArchives export or safe rendering will not be searchable.

## Integrity And Evidence

- Integrity sealing is tamper-evidence, not immutability. BenchVault can warn
  when protected files change after backup, but it cannot prevent file changes
  on a writable filesystem.
- The local integrity ledger is also a local file. If someone can alter both the
  backup folder and the local ledger, BenchVault cannot prove originality by
  itself.
- BenchVault is not a legal certification system and does not replace formal
  chain-of-custody, records retention, e-signature, litigation-hold, or
  institutional evidence procedures.
- The current seal uses SHA-256 hashes and local ledger chaining. It does not
  timestamp with an external trusted timestamp authority, notarize records, or
  anchor hashes in an external append-only log.
- Derived files such as `render_notebook.json`, readable Markdown, and search
  chunks are convenience views. The LabArchives `.7z` archive and manifests
  should remain the preservation reference.
- Audit exports are generated sidecars under `audit/` and are excluded from the
  protected-file set so exporting a report does not make a sealed backup appear
  tampered. The external hash anchor is a portable text record, but BenchVault
  does not itself submit it to an external timestamp authority or institutional
  system.

## Credentials And Local Security

- On macOS app launches, BenchVault prefers macOS Keychain for LabArchives
  access ID/access key and the OpenAI API key. It keeps non-secret setup
  metadata, UID files, user-access XML, schedules, and integrity ledgers in
  ignored local files. They are not pushed to GitHub by design.
- Existing local secret files are migrated to Keychain when read by the macOS
  app. Non-macOS platforms and test/tooling paths still use the ignored local
  file fallback until their native secure stores are implemented.
- On macOS and Linux-like systems, BenchVault attempts owner-only file
  permissions for local credential files. On Windows this permission-hardening
  path is not currently implemented.
- Credentials are not yet stored in Windows Credential Manager, iPad Keychain,
  hardware-backed secure storage, or an encrypted vault.
- Backup archives and readable sidecars are not encrypted by BenchVault. The
  selected backup folder must be protected by the operating system, disk
  encryption, institutional storage controls, or other local security measures.
- The app does not currently implement automatic credential rotation,
  revocation, secret scanning, remote wipe, or multi-user local account
  separation.

## Scheduling

- Automatic backups run only while the BenchVault app is open. There is no
  production macOS LaunchAgent, Windows Task Scheduler integration, iPad
  background task, or server-side scheduler. The repository includes an
  experimental macOS LaunchAgent installer that runs the local backup tool, but
  it is not a signed packaged helper.
- Missed scheduled runs are not currently replayed as a separate catch-up
  queue. The next run is scheduled when the app is active and setup is ready.
- Scheduled backup frequency is currently daily or weekly. There is no monthly,
  hourly, custom cron, blackout-window, or retention-policy UI.

## Platform Support

- macOS is the only platform currently built and exercised as the primary
  target.
- Windows support is scaffolded through Flutter, but host builds, credential
  permission hardening, extractor availability, file-picker behavior, and
  installer packaging still need validation on Windows.
- iPad support is scaffolded through Flutter iOS, but background scheduling,
  local archive extraction, filesystem access, document picking, and credential
  storage need platform-specific design and testing before it can be considered
  supported.
- The app is not currently distributed as a signed, notarized, managed, or
  institutionally packaged installer.

## Testing Limits

- The synthetic integration notebook is large and varied, but it is still
  generated test data. It cannot cover every LabArchives widget, institutional
  configuration, legacy notebook, or proprietary instrument payload.
- Automated tests cover parsing, settings, local search, integrity checks,
  attachment restore behavior, and read-only endpoint guardrails. They do not
  exercise every real LabArchives server behavior on every run.
- Screenshots use demo data and should not be treated as evidence that a real
  notebook backup was complete.
- The current project does not include performance benchmarks for very large
  notebook archives, thousands of attachments, low-disk conditions, network
  interruption, or simultaneous multi-user operation.

## Developer Tooling

- The quickstart PDF builder uses Python ReportLab from the available local
  Python environment. The repository does not yet pin a Python virtual
  environment or requirements file for documentation builds.
- Flutter dependencies are managed by `pubspec.yaml`, but platform packaging,
  code signing, notarization, and release automation are not complete.
- The local auth helper and synthetic seeder are scripts for development and
  testing. They are not polished end-user interfaces.
