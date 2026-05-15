# BenchVault Documentation

This folder holds the tracked project documentation and public visual assets.
Everything here uses project-relative paths. Local-only source PDFs,
credentials, auth responses, notebook IDs, and raw backups stay outside Git in
ignored folders.

## User Documents

- `user/BenchVault_Quickstart.pdf`: printable quickstart for notebook owners and
  records staff.
- `user/quickstart.md`: source for the quickstart PDF.

## Developer Documents

- `strategic_plan.md`: phased product and engineering roadmap for making
  BenchVault a first-class backup, verification, search, and offline-review
  experience.
- `implementation_limitations.md`: current known implementation boundaries,
  including read-only safety, backup coverage, viewer rendering, search,
  integrity, credentials, scheduling, and platform support.
- `platform_release_checklist.md`: macOS release gate plus Windows and iPad
  validation checklist.
- `developer/labarchives_gov_api_reference.md`: compact implementation
  reference distilled from the LabArchives GOV API notebook PDF.
- Backup reader/search sidecars are generated locally under each backup run in
  `readable/`; they are not tracked repository documents.

## Assets

- `assets/benchvault-banner.svg`: project banner for the README and GitHub preview
  contexts that render repository images.
- `assets/screenshots/`: demo-mode app screenshots used by the README and
  quickstart, including the AI notebook search surface.

## Maintenance Notes

- Regenerate the quickstart PDF after editing its Markdown source with
  `python3 tool/build_quickstart_pdf.py`.
- Refresh screenshots with `scripts/run_macos_app.sh --demo` so no local paths
  or credentials appear in public assets.
- Add implementation discoveries to the developer reference instead of reopening
  the long source PDF for routine coding work.
