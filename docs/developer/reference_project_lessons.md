# Reference Project Lessons

Last reviewed: May 15, 2026.

This note summarizes implementation ideas borrowed from two local-only reference
projects reviewed during BenchVault development. The reference projects live
outside tracked source and must not be pushed to GitHub.

## AWS Scheduled Backup Pattern

The AWS reference project backs up LabArchives notebooks with a scheduled
Lambda, DynamoDB user metadata, Secrets Manager credentials, and S3 multipart
uploads.

Useful ideas for BenchVault:

- Treat each notebook backup as an independent job with its own status,
  timestamps, failure reason, and retry path.
- Stream large notebook backups rather than assuming the full archive can sit in
  memory or temporary storage.
- Keep offsite storage optional and explicit. Institutional targets should
  verify checksums and preserve sealed manifests.
- If S3-style storage is added, prefer Object Lock or another WORM-capable
  target over ordinary bucket versioning when originality evidence matters.
- Avoid a single monolithic backup worker for many notebooks; queueing gives
  better recovery and clearer user feedback.

BenchVault adaptations already started:

- Backup run manifests now preserve queue position and per-notebook timing.
- The product roadmap keeps offsite/WORM storage separate from the local-first
  desktop core.

## Browser Explorer Pattern

The browser explorer opens LabArchives backup archives locally, reads
`notebook/db.sqlite3` with SQL, reconstructs the notebook tree, and restores
attachments from `notebook/attachments/<entry-part-id>/<version>/original/`.

Useful ideas for BenchVault:

- Support SQLite backup layouts in addition to JSON backup layouts when present.
- Use `entry_part_versions` to prefer the uploaded/original attachment version
  rather than assuming every original is under version `1`.
- Look for preserved thumbnail payloads under `thumb/` and show them when safe.
- Keep a developer diagnostics path for archive structure, but avoid exposing
  raw IDs and SQL details as normal user workflow.

BenchVault adaptations already started:

- The parser detects SQLite backups and can parse tree nodes, entry parts, and
  attachment version metadata through the local `sqlite3` command when JSON
  tables are absent.
- Rendered attachment metadata now includes original payload version and
  thumbnail path when available.
- The viewer can show preserved thumbnails while keeping restore-first behavior
  for original files.

## Guardrails

- Do not copy the reference projects into tracked source.
- Do not copy their credential patterns. Browser-side API secrets and local
  storage auth tokens are not acceptable for BenchVault production use.
- Do not render backed-up rich HTML directly. BenchVault should continue safe
  text rendering and safe local previews only.
- Treat external storage as optional evidence hardening, not as a replacement
  for the faithful local LabArchives archive.
