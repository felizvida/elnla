# ELNLA

ELNLA is a LabArchives GOV API project.

## Platform Strategy

- macOS is the first target and primary development environment.
- Windows should remain supported. Avoid macOS-only assumptions in core logic, file handling, path handling, and authentication storage.
- iPad should remain supported. UI and workflows should be touch-friendly, responsive, and usable without desktop-only interactions.
- Put platform-specific behavior behind small adapters so shared API logic stays portable.

Current implementation status:

- macOS: Flutter desktop app builds as a native `.app`.
- Windows: Flutter Windows project is scaffolded; build on a Windows host because Flutter does not cross-compile Windows desktop binaries from macOS.
- iPad: Flutter iOS project is scaffolded; this Mac needs the matching Xcode iOS platform component installed before an iPad build can complete.
- First launch: the app prompts for LabArchives email, access ID, access key, and the local folder for routine backup copies, then completes the LabArchives browser/auth-code exchange and writes local-only setup files.
- Automatic backup: the app can store a daily or weekly backup schedule with a selected local time. Scheduled backups run while the app is open.
- Backup layout: new archives are grouped under `notebooks/<notebook>/<year>/<month>/<day>/<run>/`, with run manifests under `runs/<year>/<month>/<day>/`.
- Original contents: backups keep the LabArchives `.7z` archive and verify every reported attachment against the extracted `original/` payload by byte size before marking a notebook backup successful.

## Repository Rules

- Use paths relative to the project root in tracked files.
- Never commit machine-specific absolute paths.
- Store real credentials, tokens, passwords, access keys, and local auth files only in ignored local paths such as `local_credentials/` or `.env.local`.
- Commit only placeholder templates, such as `.env.example`, with fake values.
- Keep source PDFs and other local reference inputs in `local_docs/`, which is ignored by Git.

## Local Reference

- `labarchives_gov_api_reference.md` is the compact working reference for the LabArchives GOV API.
- The source PDF is local-only at `local_docs/2026_05_14_notebook_70221.pdf`.

## Development App

- The app setup screen can refresh local user access XML and notebook IDs.
- Run `python3 scripts/labarchives_auth_flow.py --email your.email@example.gov --open-browser` only when you want the command-line setup fallback.
- Run `python3 scripts/labarchives_seed_bio_test_notebook.py` to create and populate a dedicated bio-lab integration notebook.
- Run `dart run tool/backup_once.dart` to exercise the same backup/indexing path used by the app.
- Run `flutter build macos`, then `scripts/run_macos_app.sh` to launch the native macOS app with `ELNLA_PROJECT_ROOT` set to this repository.
- Credentials, user access XML, notebook IDs, schedule settings, and backups created by the app live in ignored local paths or the user-selected backup folder.
