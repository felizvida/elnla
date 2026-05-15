# BenchVault Strategic Implementation Plan

Last reviewed: May 15, 2026.

BenchVault should become the best place to protect, verify, search, and read
LabArchives GOV notebook backups offline. It should not try to become a second
LabArchives editor. The product advantage is focus: evidence-first backup,
calm offline review, fast search, and clear integrity signals.

## North Star

BenchVault should answer three user questions within seconds:

- What notebooks are protected?
- Can I trust that this local copy has not changed since backup?
- Can I find and read the exact record, attachment, sample, protocol, or
  observation I need while offline?

The app should feel quieter, faster, and more trustworthy than the original
LabArchives interface for the backup-and-review job.

## Product Principles

- Preservation first: keep the original LabArchives archive and full-size
  attachments as the evidence reference.
- Read-only by design: production code must never create, edit, upload, delete,
  or restore content back to LabArchives.
- Explain before failing: every skip, warning, and failure should name the
  likely cause and the next useful action.
- Progressive disclosure: show a simple status first, then detailed manifests,
  hashes, paths, and logs when needed.
- Local-first: backup, browse, fuzzy search, integrity checks, and attachment
  restore should work without OpenAI or continuous network access after backup.
- Sensitive by default: never expose local absolute paths, notebook IDs,
  credentials, access XML, source PDFs, or raw backup archives in public assets.
- NIH-appropriate tone: restrained visual design, clear status language, no
  consumer-app drama, and no jargon where plain language works.

## Strategic Pillars

### 1. Backup Center

Goal: make backup status obvious before, during, and after a run.

Deliverables:

- Preflight checklist for credentials, UID, notebook list age, backup folder
  write access, available disk space, archive extractor availability, OpenAI
  optional status, and read-only API allowlist status.
- Per-notebook backup cards with owner/backup eligibility status when known,
  last successful backup, last failure, protected bytes, attachment count, and
  integrity state.
- Backup run timeline with phases: authenticate, download, extract, parse,
  verify originals, write readable copy, seal integrity, finish.
- Failure classifier for common cases: not owner, API credentials missing,
  authorization expired, extractor missing, disk full, attachment verification
  failed, network interrupted, unknown API error.
- A single primary action: `Back Up Now`.

Definition of done:

- A user can tell whether they are ready to back up without reading logs.
- A failed notebook leaves a clear reason and a suggested next action.
- The app never hides successful notebooks because a separate notebook failed.

### 2. Offline Evidence Viewer

Goal: make backed-up notebooks easier to read than the original interface when
the task is review, audit, or retrieval.

Deliverables:

- Three-pane desktop layout: backup list, notebook tree/search results, reading
  pane.
- Page breadcrumbs, page outline, part counts, comment counts, attachment
  counts, and local backup provenance.
- Polished rendering for headings, rich text, plain text, comments, simple
  tables, and links converted to readable text with URLs.
- Attachment cards showing file family, original filename, size, checksum
  status, restore action, preview status, and recommended external viewer when
  inline preview is not safe or practical.
- Integrity banner that stays visible and changes tone for verified, changed,
  legacy, missing seal, or active verification states.
- Keyboard navigation and accessible labels for common review actions.

Definition of done:

- A reviewer can move from backup run to notebook page to original attachment
  without needing to understand the archive layout.
- Viewer warnings are impossible to miss when a backup has changed.
- The viewer remains read-only and never offers a LabArchives write action.

### 3. Search And Retrieval

Goal: make finding a record dramatically faster than browsing notebook pages
manually.

Deliverables:

- Unified search across notebook names, page paths, titles, rendered text,
  comments, attachment names, attachment metadata, instrument names, sample IDs,
  and backup dates.
- Local fuzzy search with filters for notebook, date, attachment family,
  verified/unverified backup state, page/comment/attachment scope, and exact
  phrase mode.
- Optional OpenAI answer mode with clear consent language, visible model state,
  citations, and automatic local fallback.
- Result landing that jumps to the matching page and visually highlights the
  relevant part or attachment.
- Search index versioning so older backups can be upgraded or regenerated.

Definition of done:

- Common lab queries return useful local results without an OpenAI key.
- AI answers never appear without citations to backed-up pages.
- Search makes clear when binary attachment contents were not text-indexed.

### 4. Integrity, Provenance, And Audit Export

Goal: make originality checks understandable and exportable.

Deliverables:

- Integrity detail view with archive hash, manifest hash, ledger status,
  protected file count, protected bytes, checked time, changed files, missing
  files, and added files.
- Exportable audit summary for a backup run in PDF and machine-readable JSON or
  CSV.
- Optional external hash export that users can place in institutional records,
  WORM storage, or another append-only system.
- Clear distinction among original archive, derived render JSON, readable
  Markdown, search chunks, original attachment manifest, and integrity manifest.
- Future path for trusted timestamp authority or institutional notarization.

Definition of done:

- A changed byte produces a prominent warning and an exact changed-file list.
- A reviewer can export a compact report without exposing credentials.
- Documentation explains tamper-evidence versus true immutability.

### 5. Setup, Secrets, And Trust

Goal: make first launch safe and unsurprising.

Deliverables:

- Guided setup wizard: credentials, authorization, backup folder, owner-rights
  explanation, schedule, optional OpenAI key, preflight, ready state.
- Credential validation that does not require writing to any notebook.
- Platform-native secret storage plan: macOS Keychain first, then Windows
  Credential Manager and iPad Keychain.
- Backup-folder safety checks for writable folder, non-repository location,
  disk space, and warning when folder appears to be synced to an unsuitable
  location.
- Local-only data explainer that is concise and visible before credentials are
  saved.

Definition of done:

- First-time setup can be completed without reading developer docs.
- Secrets are protected by platform-native storage or a documented local fallback.
- Users know what is local, what goes to LabArchives, and what may go to OpenAI.

### 6. Platform And Packaging

Goal: ship a reliable app on macOS first, then expand deliberately.

Deliverables:

- macOS signed and notarized app bundle.
- Built-in or bundled archive extraction path so users do not need to install
  command-line tools manually.
- Windows build validation for archive extraction, folder picker, credential
  storage, scheduled backup behavior, and installer packaging.
- iPad feasibility pass for archive extraction, Files integration, background
  scheduling limits, secure storage, and offline viewer performance.
- Release checklist covering screenshots, docs, smoke tests, secret scans,
  read-only endpoint tests, and demo-mode screenshots.

Definition of done:

- macOS users can install and run without developer tooling.
- Windows/iPad are not advertised as supported until end-to-end validation
  passes on those platforms.

### 7. Documentation And Adoption

Goal: make the app understandable to records-focused lab users and maintainers.

Deliverables:

- Quickstart kept short and printable.
- Limitations document kept blunt and current.
- Developer reference kept compact and relative-path only.
- Visual demo with synthetic data only.
- Troubleshooting guide organized by symptoms, not by internal code modules.
- A one-page PI/lab-chief explanation of owner-only backup rights.

Definition of done:

- Users understand owner-only backup rights before their first failure.
- Docs never contain real credentials, raw notebook IDs, local absolute paths, or
  source PDF contents.

## Sequenced Roadmap

### Phase 0: Safety Baseline

Status: implemented for the current repo. Production read-only endpoint
allowlists, seeder opt-ins, local-only credential rules, limitations docs, and
regression tests are in place.

- Enforce production read-only LabArchives endpoint allowlist.
- Gate synthetic test-notebook writer behind explicit opt-ins.
- Keep credentials, source PDFs, notebook IDs, and raw backups out of Git.
- Document implementation limitations.
- Add regression tests for read-only behavior.

Exit criteria:

- Tests fail if production LabArchives code introduces write endpoints.
- Public docs explain read-only behavior and current limitations.

### Phase 1: Backup Center Upgrade

Target outcome: a user can understand backup readiness and failures without
opening logs.

Status: started. The first Backup Center preflight band now checks local
credentials, notebook list, backup folder writability, disk space, archive
extractor availability, read-only API guardrails, OpenAI search configuration,
and schedule state before backup starts. Backup runs also preserve structured
per-notebook outcomes, classified skip reasons, successful backup records, and
run logs in local run manifests. The backup pane now surfaces the latest run
summary, compact per-notebook outcome rows, and a detail dialog with suggested
next actions and run logs. It also shows persistent notebook status cards that
combine latest outcome, prior local copies, and original-attachment verification
state.

Implementation tasks:

- Expand the `PreflightCheck` model and service as new readiness checks become
  useful.
- Continue refining the backup dashboard summary strip as more metadata becomes
  available.
- Continue enriching persistent per-notebook backup status cards with integrity
  recheck state and attachment counts.
- Continue expanding stable user-facing failure categories.
- Continue preserving run-level logs in local backup metadata without storing
  credentials.

Exit criteria:

- Manual backup shows preflight, progress, per-notebook outcome, and next action
  for each failure.

### Phase 2: Evidence Viewer Upgrade

Target outcome: offline reading feels purpose-built and polished.

Status: implemented for the first production slice. Attachment cards expose
original-payload indexing, LabArchives-viewable status, reported byte size,
relative original payload path, and a restore action. The reader shows page
breadcrumbs, part/comment/attachment counts, and a compact page outline. The
viewer also exposes an integrity detail dialog.

Implementation tasks:

- Refine the wide and narrow layouts around backup list, notebook tree, and
  reading pane.
- Continue refining page breadcrumbs and local page outline.
- Improve rich-text/table rendering without executing active content.
- Continue redesigning attachment cards around preview, preserve, restore, and
  provenance.
- Add a richer integrity drawer or export flow after the current detail dialog.

Exit criteria:

- A demo notebook page with text, comments, links, and attachments is easier to
  review in BenchVault than in the raw LabArchives export.

### Phase 3: Search Upgrade

Target outcome: search becomes the fastest way to retrieve evidence.

Status: implemented for the first production slice. Local fuzzy search and
OpenAI answer mode are available, with filters for all content, page text,
attachments, comments, exact phrase, and verified backups only.

Implementation tasks:

- Continue improving result grouping.
- Add result-to-page highlighting.
- Improve index metadata for sample IDs, instruments, attachment families, and
  dates.
- Continue refining OpenAI consent/status UI.
- Add search-index migration/version checks.

Exit criteria:

- Local search finds expected records in the synthetic notebook across titles,
  comments, attachment names, and rendered text.

### Phase 4: Audit Export And Provenance

Target outcome: integrity evidence can leave the app cleanly.

Status: implemented for the first production slice. The viewer exposes an
integrity detail dialog with manifest path, local seal state, checked file
count, checked bytes, manifest hashes, and changed, missing, or unexpected
files. It can export a local audit packet with Markdown, JSON, and CSV sidecars
plus a portable external hash-anchor text file under the backup run's `audit/`
folder.

Implementation tasks:

- Continue improving backup-run audit report generation.
- Continue improving JSON/CSV export for manifests and verification summaries.
- Add external timestamp or institutional submission workflow for exported
  hashes.
- Add changed-file comparison view.

Exit criteria:

- A verified backup can produce a concise audit packet without exposing secrets.

### Phase 5: Secure Storage And Packaging

Target outcome: macOS installation and credential handling feel professional.

Implementation tasks:

- Move credentials to macOS Keychain with migration from local env files.
- Bundle or validate archive extraction dependencies.
- Sign and notarize macOS app.
- Keep the release smoke-test checklist current.

Status: partially implemented. The app has first-launch credential setup,
local-only ignored credential files, owner-rights explanation, backup folder
selection, schedule setup, and a release smoke-test script. Native Keychain,
signing, notarization, and installer work remain external release tasks.

Exit criteria:

- A non-developer macOS user can install, set up, back up, and view offline with
  no command-line work.

### Phase 6: Windows And iPad Validation

Target outcome: platform claims match reality.

Implementation tasks:

- Validate Windows archive extraction, file paths, credential storage, folder
  picker, and packaging.
- Validate iPad Files access, secure storage, archive extraction feasibility,
  UI ergonomics, and background limits.
- Update docs and limitations based on real platform behavior.

Status: documented scaffold. The platform release checklist names the Windows
and iPad validation gates. These platforms remain unvalidated until tested on
their respective hosts/devices.

Exit criteria:

- Each platform has a documented support level backed by a working smoke test.

## Immediate Next Sprint

Recommended next implementation order:

- Enrich notebook status cards with per-card integrity recheck state once that
  can be computed cheaply.
- Add result-to-page highlighting and richer result grouping.
- Add external hash export or institutional timestamp/notarization workflow.
- Replace local credential files with platform-native secure storage.

This sprint gives the largest UX improvement while preserving the read-only
backup core.

## Success Metrics

- Time from first launch to first successful backup is under 5 minutes for a
  prepared notebook owner.
- A skipped non-owned notebook produces an understandable owner-rights message.
- A changed protected file produces a visible warning before the user reads the
  backup.
- Local fuzzy search returns useful results for sample IDs, instruments,
  protocols, page titles, comments, and attachment names.
- Demo screenshots contain only synthetic data.
- Repository scans find no local absolute paths, credentials, raw backups,
  source PDFs, or notebook IDs.
- Production tests fail on LabArchives write endpoint introduction.

## Risks To Manage

- LabArchives archive layout may change. Keep parser tests and fixture archives
  current.
- Large notebooks may expose performance and storage issues. Add benchmarks
  before broad deployment.
- Credential storage needs platform-specific care. Do not overstate security
  until Keychain or equivalent storage is implemented.
- Integrity warnings can be misunderstood as legal proof. Keep tamper-evidence
  language precise.
- AI search can create policy concerns. Keep it optional, cited, minimal, and
  easy to disable.

## Non-Goals

- Editing LabArchives notebooks.
- Replaying or restoring records back into LabArchives.
- Replacing institutional records-management systems.
- Running active content from backed-up attachments.
- Guaranteeing legal admissibility by itself.
- Advertising Windows or iPad as fully supported before validation.
