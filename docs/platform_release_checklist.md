# BenchVault Platform And Release Checklist

BenchVault is macOS-first. Windows and iPad are scaffolded Flutter targets until
they pass this checklist on real devices or platform hosts.

## Release Gate

A release candidate should not be published until all local-only and safety
checks pass:

- `flutter test`
- `flutter analyze`
- `git diff --check`
- secret and absolute-path scan across tracked public files
- synthetic notebook seeder dry run confirms write lock
- demo-mode app launch
- quickstart PDF regenerated from `docs/user/quickstart.md`

## macOS

Required before a public macOS build:

- Build `BenchVault.app` with `flutter build macos`.
- Launch with `scripts/run_macos_app.sh --demo`.
- Confirm first-launch credential setup does not contact LabArchives until the
  user chooses a connection action.
- Confirm manual backup preflight blocks missing credentials.
- Confirm backup folder picker works.
- Confirm attachment restore copies a file without overwriting an existing file.
- Confirm integrity warnings appear when a protected file changes.
- Confirm audit export writes Markdown, JSON, and CSV sidecars under the backup
  run's `audit/` folder.
- Sign and notarize the app before distributing outside local development.

## Windows

Windows should stay documented as scaffolded until this is performed on a
Windows host:

- Build with `flutter build windows`.
- Confirm folder picker paths, path separators, and relative backup paths.
- Confirm archive extraction finds `7z`, `tar`, or another supported extractor.
- Confirm local credential files are written with appropriate user-only
  permissions or replaced with Windows Credential Manager integration.
- Confirm scheduled backup behavior while the app is open.
- Confirm attachment restore and audit export work with Windows paths.

## iPad

iPad should stay documented as scaffolded until this is performed on a real iPad
or simulator with Files access:

- Build and launch the Flutter iOS target.
- Confirm local file access through the Files app works for user-selected backup
  folders.
- Confirm archive extraction is feasible within iPad storage and sandbox limits.
- Confirm credential storage uses iPad Keychain or a documented local fallback.
- Confirm background scheduling limits are accurately reflected in the UI and
  docs.
- Confirm large notebook rendering and search remain responsive.

## Secure Storage Direction

Current macOS app launches prefer macOS Keychain for LabArchives and OpenAI
secrets, with ignored local files used for non-secret setup metadata and
fallback/test paths. Production packaging should still validate secure storage
behavior before broad distribution:

- Windows Credential Manager for Windows.
- iPad Keychain for iPad.

Until Windows and iPad integrations are implemented and validated, BenchVault
should state plainly that those platforms use local fallback behavior and are not
fully supported release targets.
