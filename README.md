# ELNLA

ELNLA is a LabArchives GOV API project.

## Platform Strategy

- macOS is the first target and primary development environment.
- Windows should remain supported. Avoid macOS-only assumptions in core logic, file handling, path handling, and authentication storage.
- iPad should remain supported. UI and workflows should be touch-friendly, responsive, and usable without desktop-only interactions.
- Put platform-specific behavior behind small adapters so shared API logic stays portable.

## Repository Rules

- Use paths relative to the project root in tracked files.
- Never commit machine-specific absolute paths.
- Store real credentials, tokens, passwords, access keys, and local auth files only in ignored local paths such as `local_credentials/` or `.env.local`.
- Commit only placeholder templates, such as `.env.example`, with fake values.
- Keep source PDFs and other local reference inputs in `local_docs/`, which is ignored by Git.

## Local Reference

- `labarchives_gov_api_reference.md` is the compact working reference for the LabArchives GOV API.
- The source PDF is local-only at `local_docs/2026_05_14_notebook_70221.pdf`.
