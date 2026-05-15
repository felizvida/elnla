![BenchVault banner](docs/assets/benchvault-banner.svg)

# BenchVault

BenchVault is a macOS-first LabArchives GOV backup and read-only viewer for
electronic lab notebooks. It helps eligible notebook owners preserve the
full-size LabArchives archive, verify original attachment files, and browse
backed-up notebooks without writing anything back to LabArchives.

## Why It Exists

At NIH and NICHD, lab notebook owners are lab chiefs/PIs. LabArchives full-size
notebook backup is owner-only: users who can view a notebook are not necessarily
allowed to download its full-size backup archive. BenchVault makes that rule visible
in the app and in the documentation so backup failures are easier to understand.

## Screenshots

![BenchVault AI notebook search](docs/assets/screenshots/benchvault-ai-search.png)

![BenchVault read-only viewer](docs/assets/screenshots/benchvault-viewer.png)

![BenchVault automatic backup schedule](docs/assets/screenshots/benchvault-schedule.png)

## What It Does

- Prompts for LabArchives GOV credentials on first launch.
- Lets the user choose the local folder for routine backup copies.
- Runs a Backup Center preflight for local credentials, notebook list, backup
  folder writability, disk space, archive extraction, read-only API guardrails,
  search configuration, and schedule state.
- Records structured per-notebook run outcomes with classified skip reasons and
  local run logs, then surfaces persistent notebook status cards in the backup
  pane.
- Backs up every notebook the authenticated user owns and can back up through
  the LabArchives API.
- Uses a production read-only LabArchives allowlist for login, user-access
  lookup, and notebook backup download only; it does not add, update, delete,
  upload, or restore content to LabArchives.
- Keeps the original LabArchives `.7z` archive for preservation.
- Extracts and indexes notebook pages for local read-only viewing.
- Shows page breadcrumbs, page counts, comment counts, attachment counts, and a
  compact page outline in the offline reader.
- Writes a separate readable Markdown copy plus JSONL search chunks for every
  successful backup.
- Provides notebook search with local fuzzy fallback and OpenAI-powered
  natural-language answers when the user saves an OpenAI API key locally,
  including filters for text, attachments, comments, exact phrase, and verified
  backups.
- Recognizes LabArchives attachment families in the viewer, including browser
  images, text/tabular files, PDFs, Office documents, Jupyter notebooks,
  SnapGene/sequence files, chemical structure files, media, archives, and
  unknown custom formats.
- Shows attachment preservation evidence in the viewer, including original
  payload indexing, LabArchives-viewable status, byte size, and restore action.
- Verifies reported original attachment files by byte size before marking a
  notebook backup successful.
- Seals each successful backup with a SHA-256 integrity manifest and warns in
  the viewer if any protected file changes later.
- Exports local audit summaries for backup runs as Markdown, JSON, and CSV
  sidecars without exposing credentials.
- Stores credentials, user access XML, notebook IDs, schedules, and backups in
  local ignored paths or in the user-selected backup folder.
- Supports manual backup plus daily or weekly scheduled backup while the app is
  open.

## Platform Strategy

- macOS is the first target and primary development environment.
- Windows support is scaffolded through Flutter; build on a Windows host.
- iPad support is scaffolded through Flutter iOS; build on a Mac with the
  required Xcode iOS platform components installed.
- Shared LabArchives, backup, parsing, and verification logic stays in Dart so
  platform-specific code remains small.
- Visual styling uses an NIH/HHS-aligned palette: federal blue as the primary
  action color, gold as a restrained secondary accent, and cool grays for
  dense notebook review surfaces.

Current status:

| Platform | Status |
| --- | --- |
| macOS | Native Flutter `.app` builds and runs. |
| Windows | Project scaffolded; host build still needed. |
| iPad | Project scaffolded; Xcode iOS platform setup still needed. |

## Repository Layout

```text
docs/
  strategic_plan.md
  implementation_limitations.md
  assets/
    benchvault-banner.svg
    screenshots/
  developer/
    labarchives_gov_api_reference.md
  user/
    BenchVault_Quickstart.pdf
    quickstart.md
lib/
  main.dart
  src/
scripts/
test/
tool/
```

## Documentation

- [Quickstart PDF](docs/user/BenchVault_Quickstart.pdf)
- [Quickstart source](docs/user/quickstart.md)
- [Strategic implementation plan](docs/strategic_plan.md)
- [Implementation limitations](docs/implementation_limitations.md)
- [Platform release checklist](docs/platform_release_checklist.md)
- [LabArchives GOV API working reference](docs/developer/labarchives_gov_api_reference.md)
- [Documentation index](docs/README.md)

The original LabArchives API source PDF is intentionally local-only under
`local_docs/` and is ignored by Git. The compact developer reference is the
tracked substitute used during implementation.

## Current Limitations

BenchVault is macOS-first and focused on LabArchives GOV backup/offline viewing.
It is not a LabArchives editor, legal certification system, immutable storage
system, or background service. Automatic backups currently run only while the
app is open, readable views simplify some LabArchives formatting, and Windows
and iPad support still need platform validation. See the
[implementation limitations](docs/implementation_limitations.md) for the full
list.

## License

Apache-2.0. See [LICENSE](LICENSE).

## Local-Only Data Rules

- Use paths relative to the project root in tracked files.
- Never commit machine-specific absolute paths.
- Never commit real credentials, tokens, access keys, local auth XML, notebook
  IDs, downloaded source PDFs, or raw notebook backups.
- Keep local setup files under ignored paths such as `local_credentials/`,
  `local_docs/`, `.env.local`, or a user-selected backup folder outside the
  repository.
- Commit placeholder templates only when examples are needed.

## Development

```sh
flutter analyze
flutter test
flutter build macos
scripts/run_macos_app.sh
```

Useful helper commands:

```sh
python3 scripts/labarchives_auth_flow.py --email your.email@example.gov --open-browser
dart run tool/backup_once.dart
python3 tool/build_quickstart_pdf.py
scripts/release_smoke_check.sh
scripts/package_macos_release.sh 1.0.1
```

Release automation:

- `.github/workflows/ci.yml` runs tests, analyzer, safety scans, seeder dry-run,
  and a macOS build on push and pull request.
- `.github/workflows/release.yml` runs on `v*` tags, builds the unsigned macOS
  prerelease zip, and uploads it to the matching GitHub release.

The synthetic test-notebook seeder is intentionally write-capable and is locked
behind a double opt-in so it cannot be run accidentally:

```sh
BENCHVAULT_ALLOW_LABARCHIVES_TEST_WRITES=YES_WRITE_SYNTHETIC_TEST_NOTEBOOK \
  python3 scripts/labarchives_seed_bio_test_notebook.py \
  --i-understand-this-writes-to-labarchives-test-notebook
```

For clean public screenshots, run the app with demo data:

```sh
scripts/run_macos_app.sh --demo
```
