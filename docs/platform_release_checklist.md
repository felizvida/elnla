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
- `flutter build macos`
- `scripts/package_macos_release.sh <version>`
- GitHub Actions Windows job passes `flutter build windows`
- GitHub Actions iPadOS job passes `flutter build ios --release --no-codesign`
- `scripts/package_windows_release.ps1 <version>` on a Windows host
- `scripts/package_ipados_validation.sh <version>` on a macOS host
- demo-mode app launch
- quickstart PDF regenerated from `docs/user/quickstart.md`
- GitHub Actions CI passes on `main`

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
- If testing closed-app scheduling, install the experimental LaunchAgent with
  `scripts/install_macos_launch_agent.sh --hour 2 --minute 0`, confirm
  `tool/backup_once.dart` writes logs under ignored local credentials, then
  remove it with `scripts/uninstall_macos_launch_agent.sh`.
- Sign and notarize the app before distributing outside local development.
- The tag workflow builds and uploads an unsigned prerelease zip. Signed and
  notarized distribution still requires Apple Developer credentials.

## Windows

Windows now has CI build validation and prerelease zip packaging on
`windows-latest`. It should stay documented as a prerelease validation target
until this checklist is completed on real NIH/NICHD Windows workstations:

- Build with `flutter build windows`.
- Package with `pwsh scripts/package_windows_release.ps1 <version>`.
- Confirm the GitHub release includes `BenchVault-Windows-v<version>-prerelease.zip`
  and `SHA256SUMS-Windows.txt`.
- Confirm folder picker paths, path separators, and relative backup paths.
- Confirm archive extraction finds `7z`, `tar`, or another supported extractor.
- Confirm local credential files are written with appropriate user-only
  permissions or replaced with Windows Credential Manager integration.
- Confirm scheduled backup behavior while the app is open.
- Confirm attachment restore and audit export work with Windows paths.
- Add installer packaging, Authenticode signing, and endpoint/security review
  before broad Windows distribution.

## iPad

iPadOS now has a no-codesign CI validation build. The GitHub release uploads an
unsigned validation zip for signing review only; it is not an installable iPad
release. iPad should stay documented as a prerelease validation target until
this is performed on a real iPad or simulator with Files access:

- Build and launch the Flutter iOS target.
- Package the unsigned validation bundle with
  `scripts/package_ipados_validation.sh <version>`.
- If the build reports no eligible iOS destination, install the required iOS
  platform/runtime in Xcode Settings > Components and rerun the validation.
- Confirm the GitHub release includes
  `BenchVault-iPadOS-v<version>-unsigned-validation.zip` and
  `SHA256SUMS-iPadOS-validation.txt`.
- Confirm local file access through the Files app works for user-selected backup
  folders.
- Confirm archive extraction is feasible within iPad storage and sandbox limits.
- Confirm credential storage uses iPad Keychain or a documented local fallback.
- Confirm background scheduling limits are accurately reflected in the UI and
  docs.
- Confirm large notebook rendering and search remain responsive.
- Add Apple Developer signing, provisioning profile management, entitlement
  review, and TestFlight or managed-app distribution before calling this an iPad
  release.

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
