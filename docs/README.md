# ELNLA Documentation

This folder holds the tracked project documentation and public visual assets.
Everything here uses project-relative paths. Local-only source PDFs,
credentials, auth responses, notebook IDs, and raw backups stay outside Git in
ignored folders.

## User Documents

- `user/ELNLA_Quickstart.pdf`: printable quickstart for notebook owners and
  records staff.
- `user/quickstart.md`: source for the quickstart PDF.

## Developer Documents

- `developer/labarchives_gov_api_reference.md`: compact implementation
  reference distilled from the LabArchives GOV API notebook PDF.
- Backup reader/search sidecars are generated locally under each backup run in
  `readable/`; they are not tracked repository documents.

## Assets

- `assets/elnla-banner.svg`: project banner for the README and GitHub preview
  contexts that render repository images.
- `assets/screenshots/`: demo-mode app screenshots used by the README and
  quickstart.

## Maintenance Notes

- Regenerate the quickstart PDF after editing its Markdown source.
- Refresh screenshots with `scripts/run_macos_app.sh --demo` so no local paths
  or credentials appear in public assets.
- Add implementation discoveries to the developer reference instead of reopening
  the long source PDF for routine coding work.
