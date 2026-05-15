# LabArchives GOV API Working Reference

Source PDF: kept local-only in an ignored path and not committed to Git.

Generated from: LabArchives GOV API Complete Notebook, generated May 14, 2026 at 03:30 PM EDT.

Purpose: compact working notes for future coding. Use this first before reopening the 210-page PDF. Enrich this file whenever implementation work uncovers more details, hidden API behavior, or useful coding patterns.

Repository path convention: tracked files must use paths relative to the project root. Do not commit machine-specific absolute paths.

Credential convention: real credentials, tokens, passwords, access keys, local auth files, and downloaded source documents must stay in macOS Keychain or ignored local paths such as `local_credentials/`, `.env.local`, or `local_docs/`. GitHub should only receive placeholder templates such as `.env.example` with fake values.

## Document Map

- Pages 4-7: terms, overview, requirements, best practices.
- Pages 8-24: ELN overview, authentication, UID flow, container file, entry XML model.
- Pages 25-118: ELN API classes and methods.
- Pages 119-122: ELN change log and error codes.
- Pages 123-161: Scheduler overview, auth, errors, endpoints.
- Pages 162-210: Inventory overview, auth, endpoints.

## Global Implementation Rules

- GOV base URL: `https://api.labarchives-gov.com`.
- ELN supports HTTPS only.
- Do not share API credentials outside the issued organization or purpose.
- Make base URL and credentials configurable if code may run in more than one LabArchives region/site.
- Do not burst many calls at once. Prefer serial calls, or stagger calls with at least 1 second between them.
- Do not immediately retry failed calls. Use bounded exponential backoff.
- Do not retry HTTP 4xx blindly. Treat most 4xx responses as client/configuration issues.
- Search and existence methods may return HTTP 404 for "no match found"; this is expected behavior.
- Use `utilities::epoch_time` at app/session start to compare server time and adjust the `expires` value if the client clock is off.
- The `expires` parameter is confusingly named in the ELN docs: it should be based on current epoch time, adjusted for server/client clock skew, not a far-future expiry.

## BenchVault Read-Only Contract

BenchVault is for backup and offline viewing. Production code must not write,
edit, restore, upload, or otherwise mutate the original LabArchives notebook.

Production LabArchives access is limited to:

- `GET /api_user_login`: browser authorization handoff.
- `GET /api/users/user_access_info`: exchange the returned auth code for UID
  and user notebook metadata.
- `GET /api/notebooks/notebook_backup`: download the full-size backup archive.

Implementation guardrails:

- Route ELN URLs through the typed read-only allowlist in
  `lib/src/labarchives_client.dart`; do not add generic endpoint builders to
  production code.
- Keep production LabArchives calls on `GET`; never use POST, PUT, PATCH,
  DELETE, or upload helpers against LabArchives in `lib/`.
- Reject extra backup parameters that would weaken preservation, especially
  `no_attachments=true`.
- Keep all writes local: credentials under ignored local files, archives under
  the user-selected backup folder, readable/search sidecars under the backup
  run, and integrity ledgers under ignored local files.
- The viewer may restore an attachment only by copying the backed-up original
  payload to a user-selected local folder. It must never restore back to
  LabArchives.

Endpoints that are write-capable and must stay out of production include
`entries::add_entry`, `entries::add_attachment`, `entries::add_comment`,
`tree_tools::insert_node`, `notebooks::create_notebook`, and any method whose
name begins with `add_`, `create_`, `delete_`, `insert_`, `move_`, `remove_`,
`replace_`, `restore_`, `share_`, `submit_`, `update_`, or `upload_`.

The synthetic integration-notebook seeder is separate from the app. It is the
only write-capable helper and is locked behind both
`BENCHVAULT_ALLOW_LABARCHIVES_TEST_WRITES=YES_WRITE_SYNTHETIC_TEST_NOTEBOOK`
and `--i-understand-this-writes-to-labarchives-test-notebook`.

## Authentication

### ELN Query Parameters

ELN API calls authenticate with query parameters:

- `akid`: LabArchives access key ID.
- `expires`: epoch timestamp in milliseconds.
- `sig`: URL-encoded signature.

ELN signature input:

```text
<Access Key ID> + <api method called> + <expires>
```

Then compute Base64-encoded HMAC using the access password as key. The PDF text extraction truncates the exact algorithm line, but Scheduler and Inventory specify HMAC explicitly; ELN examples match the older LabArchives HMAC-SHA1 style.

Important ELN method-name rule:

- For `/api/entries/entry_attachment`, the method string is `entry_attachment`.
- Do not include the class name `entries` in the ELN signature input.

Example signature input from the PDF:

```text
0234wedkfjrtfd34erentry_attachment264433207000
```

### Scheduler Headers

Scheduler uses the shared LabArchives auth flow, but sends auth data in HTTP headers:

- `X-LabArchives-UserId`: LabArchives UID from auth flow.
- `X-LabArchives-AKId`: access key ID.
- `X-LabArchives-Signature`: computed signature, not URL encoded.
- `X-LabArchives-Expires`: timestamp used in signature.
- `X-LabArchives-OrganizationId`: Scheduler organization ID, except `/v1/me` ignores it.

Scheduler signature method string:

- Use the relative API path, for example `/v1/me`.
- Include route path parameter values.
- Do not include query string parameters.
- Generate a new signature for every request.
- Signature algorithm documented as Base64 HMAC-SHA1 with access password as key.

### Inventory Headers

Inventory uses the same header pattern as Scheduler, with lab scoping:

- `X-LabArchives-UserId`
- `X-LabArchives-AKId`
- `X-LabArchives-Signature`
- `X-LabArchives-Expires`
- `X-LabArchives-LabId`: current Inventory lab ID, except `/public/v1/users/me` ignores it.

Inventory signature method string:

- Use the relative API path, for example `/public/v1/users/me`.
- Include route path parameter values.
- Do not include query string parameters.
- Generate a new signature for every request.
- Signature algorithm documented as Base64 HMAC-SHA-512 with access password as key.

## UID And User Login

Most ELN functionality requires `uid`, a user ID specific to the `akid` that obtained it.

Properties:

- A UID is valid only with the matching `akid`.
- A UID is persistent until the user revokes it.
- Store UID when implementing auto-login or admin workflows.
- API credentials alone do not grant access to user notebook data.

OAuth-like login flow:

1. Redirect user to `<baseurl>/api_user_login`.
2. Include `akid`, `expires`, `sig`, and `redirect_uri`.
3. For this flow, the signature method component is the raw `redirect_uri`, not URL-encoded, not the string `redirect_uri`.
4. LabArchives redirects back with `auth_code` and `email`, or with `error`.
5. Call `users::user_access_info` with `login_or_email` and `password=<auth_code>` to get UID and user data.

Alternative:

- User can obtain a time-limited access token from the LabArchives web app.
- Pass that token as the `password` parameter to `users::user_access_info`.

Account creation:

- `users::create_user_account` can create a new LabArchives account and optionally a notebook.
- It returns the same kind of user/notebook XML as `user_access_info`.
- It sends an activation email.

## ELN Entry XML Model

Many ELN responses return `<entry>` elements.

Common fields:

- `eid`: entry ID.
- `created-at`, `updated-at`: UTC datetimes.
- `last-modified-verb`, `last-modified-by`, `last-modified-ip`.
- `part-type`: entry type.
- `version`: revision number.
- Attachment fields: `attach-file-name`, `attach-file-size`, `attach-content-type`, `caption`.
- `user-access`: read/write/comment privileges.
- `change-description`.
- `thumb-info`: `none`, `generic`, or `unique`.
- `entry-url`: online URL for viewing/editing.
- Optional `entry-data`, if requested with `entry_data=true`.
- Optional `comments`, if requested with `comment_data=true`.
- Search responses may include `nbid`, `notebook`, `tree_path_ids`, `tree_path`.

Entry data by `part-type`:

- `Attachment`: `entry-data` is the caption, not the file. Use `entries::entry_attachment` for the file.
- `plain text entry`: plain text.
- `heading`: plain text heading.
- `text entry`: HTML fragment.
- `widget entry`: JSON/HTML, potentially including JS/CSS.
- `sketch entry`: non-standard JSON.
- `reference entry`: PubMed-style XML.
- `equation entry`: MathML or LaTeX/TeX.
- `assignment entry`: course edition assignment data.

Opening `entry-url`:

Append API auth and `api_auth=true`:

```text
{entry-url}{? or &}api_auth=true&uid={uid}&akid={akid}&expires={expires}&sig={sig}
```

Check whether `entry-url` already has `?` before appending.

## ELN Container Files

An LA container file is a ZIP that includes:

- Application/target file.
- Preview/thumbnail file.
- Index file with UTF-8 searchable text.
- `lamanifest.xml`.

Manifest elements:

- `application_file name`: actual stored/downloaded file.
- `preview_file name`: thumbnail or preview, PDF or image.
- `caption`: optional caption.
- `change_description`: optional update description.
- `index_file name`: UTF-8 text for LabArchives indexing.

PDF previews can be multi-page and override automatically generated thumbnails. Image previews are standard image types and cannot be multi-page.

## ELN API Classes

### Entries

- `add_attachment` (`POST`): upload a new attachment to a notebook page. Body must be raw `application/octet-stream`, not `application/x-www-form-urlencoded` or `multipart/form-data`. Key params: `uid`, `filename`, optional `caption`, `nbid`, `pid`, `change_description`, `client_ip`.
- `attachment_last_uploaded_at` (`GET`): returns last upload timestamp for an attachment. Params: `uid`, `eid`.
- `entry_attachment` (`GET`): download attachment file. For LA container uploads, returns the main data file, not the whole container. Params: `uid`, `eid`.
- `entry_thumb` (`GET`): download attachment thumbnail. Params: `uid`, `eid`.
- `entry_info` (`GET`): get entry metadata/current version. Params: `uid`, `eid`, optional `entry_data=true`, `comment_data=true`.
- `update_attachment` (`POST`): replace existing attachment. Same raw body rule as `add_attachment`; includes `eid`.
- `add_entry` (`GET` or `POST`): add `text entry`, `plain text entry`, or `heading` to a page. Params include `uid`, `nbid`, `pid`, `part_type`, `entry_data`.
- `update_entry` (`GET` or `POST`): replace data for existing text/plain/heading entry. Params: `uid`, `eid`, `entry_data`.
- `add_comment` (`GET` or `POST`): add plain text comment. Params: `uid`, `eid`, `comment_data`.
- `delete_comment` (`GET`): delete comment if permitted. Params: `uid`, `cid`.
- `entry_snapshot` (`GET`): download snapshot for widget/sketch entry. Params: `uid`, `eid`.

### Search Tools

- `attachment_search` (`GET`): search attachments across one notebook or all user notebooks. Filters include extension list, date range, query terms, notebook, hidden/student notebook options. Returns entries with notebook/path context.
- `most_recently_modified_attachment_by_extension` (`GET`): find most recently modified attachments by extension. Params include `uid`, `extension`, `max_to_return`, optional `nbid`, hidden/student notebook flags.
- `modified_since` (`GET`): find entries modified since a UTC datetime. Ordered newest first. Params include `uid`, optional `since_time`, `max_to_return`, optional `nbid`, hidden/student notebook flags.
- `entry_search` (`GET`): search entries in a notebook using LabArchives search syntax. Params include `uid`, `query`, `page_size`, `page_number`, likely notebook scope.

### Utilities

- `epoch_time` (`GET`): returns LabArchives server epoch milliseconds. Does not require `sig` or `expires`, but calls are tracked and abuse can be blocked.
- `promo_message` (`GET`): returns access-ID-specific promo text, often empty.
- `suggested_thumbnail_size` (`GET`): returns suggested thumbnail dimensions for LA container previews. Params: either `ext` or `mimetype`; `mimetype` wins if both are provided.

### Users

- `create_user_account` (`GET`): create user and optionally notebook. Params include `email`, optional `fullname`, `notebook_name`, `campaign_code`, `sso_id`, etc.
- `email_has_account` (`GET`): check if email has a LabArchives account. Param: `email`.
- `user_access_info` (`GET`): redeem auth code/token and email to get UID, user info, notebooks. Params: `login_or_email`, `password`, optional `student_notebooks`, `hidden_notebooks`.
- `user_info_via_id` (`GET`): auto-login style lookup by UID. Params: `uid`, optional `student_notebooks`, `hidden_notebooks`, `authenticated=true`.
- `max_file_size` (`GET`): max file size for a user. Param: `uid`.

### Tree Tools

- `get_tree_level` (`GET`): traverse notebook tree one level at a time. Params: `uid`, `nbid`, `parent_tree_id`; root is `0`.
- `get_entries_for_page` (`GET`): list entries on a page user can access. Params: `uid`, `page_tree_id`, `nbid`, optional `entry_data`, `comment_data`.
- `get_node` (`GET`): get tree node metadata. Params: `uid`, `nbid`, `tree_id`.
- `update_node` (`GET`): move/rename/reorder node. Params: `uid`, `nbid`, `tree_id`, optional `parent_tree_id`, `display_text`, `node_position`.
- `insert_node` (`GET`): create folder/page node under parent. Params: `uid`, `nbid`, `parent_tree_id`, `display_text`, `is_folder`.

### Notifications

- `notification_counts` (`GET`): unread/total notification counts by type. Param: `uid`.
- `get_notifications` (`GET`): list notifications newest first. Filters include `action_types`, `unread_only`, `nbid`, `num_to_return`, `last_action_viewed`.
- `mark_as_read` (`GET` or `POST`): mark notifications read. Params: `uid`, `aids` as semicolon-delimited IDs or `all`. Irreversible.

### Notebooks

- `create_notebook` (`GET`): create notebook owned by UID user. Params: `uid`, `name`, optional `site_notebook_id`, optional `initial_folders`. Initial folder values include `Biomedical` default, `Classroom`, `Lab-Project`, `Lab-Wide`, `Empty`.
- `notebook_info` (`GET`): notebook settings/details. Params: `uid`, `nbid`. UID must be owner or have Site API Access Rights.
- `modify_notebook_info` (`GET`): change notebook name/settings. Params include `uid`, `nbid`, optional `name`, `site_notebook_id`, `signing`, `add_entry_position`.
- `notebook_users` (`GET`): list users for notebook. Params: `uid`, `nbid`.
- `notebooks_with_user` (`GET`): notebooks owned by UID user that another email has access to. Params: `uid`, `email`.
- `add_user_to_notebook` (`GET`): add user and optionally role. Params: `uid`, `nbid`, `email`, optional `user_role`.
- `remove_user_from_notebook` (`GET`): remove user. Params: `uid`, `nbid`, `email`.
- `set_user_role` (`GET`): change existing notebook user's role. Params: `uid`, `nbid`, `email`, `user_role`.
- `notebook_backup` (`GET`): download notebook archive. Params: `uid`, `nbid`, optional `json=true`, `no_attachments=true`. Default archive format is `.7z`.
- `modify_notebook_metadata` (`GET`): update description and up to four project IDs. Requires owner or Site API Access Rights.
- `notebook_metadata` (`GET`): read notebook description/project IDs. Requires owner or Site API Access Rights.
- `transfer_notebook_ownership` (`GET`): transfer notebook ownership from current owner UID to existing notebook member by email. Ex-owner becomes Notebook Administrator.

Notebook roles:

- `NOTEBOOK ADMINISTRATOR` and `ADMINISTRATOR` are synonymous.
- `USER`
- `GUEST`
- `ACCOUNT ADMINISTRATOR` is not valid as a notebook role.
- Notebook owner cannot be changed except via `transfer_notebook_ownership`.

Admin best-practice warning:

- Do not use one admin account to permanently own thousands of notebooks. Performance can degrade severely. An admin account may create/manage notebooks owned by other users.

### Site License Tools

These require a UID with Site API Access Rights:

- `site_project_id_labels`: get up to four site project ID labels.
- `usage_report`: download current Detailed Usage Report.
- `notebook_usage_report`: download current Notebook Usage Report.
- `pdf_generation_report`: download current PDF/Offline Notebook Generation Report.
- `modify_project_id_labels`: set project ID labels 1-4.
- `report_url`: preferred newer method for temporary report download URL. `report_name` values: `site_usage`, `site_notebook_usage`, `site_pdf_generation`.

## ELN Error Codes

Common codes:

- `4500`: missing mandatory parameter.
- `4501`: no read rights.
- `4502`: no modify rights.
- `4503`: API method does not exist.
- `4504`: `expires` too old.
- `4506`: invalid `akid`.
- `4507`: no user for UID.
- `4509`: invalid notebook ID.
- `4510`: problem adding entry.
- `4511`: entry did not contain attachment.
- `4512`: entry not found.
- `4514`: login/access code/token/password incorrect.
- `4516`: email already assigned to an account.
- `4517`: unable to locate page.
- `4518`: POST data was not `application/octet-stream`.
- `4520`: invalid signature.
- `4521`: max file size exceeded.
- `4524`: invalid email format.
- `4527`: unsupported entry type.
- `4528`: comment not found.
- `4529`: invalid parameter value.
- `4531`: uploaded Office document invalid.
- `4532`: virus detected.
- `4533`: session timed out.
- `4999`: unexpected failure.

## Scheduler API

Overview:

- Only version documented: `v1`.
- Request/response media type: JSON.
- Non-200 responses include an `errors` array with `code`, `message`, `details`.
- Auth errors include:
  - `2000`: invalid auth header, UID, AKID, or signature.
  - `2001`: invalid Scheduler user; user must have logged into Scheduler web UI at least once.

Endpoints:

- `GET /v1/me`: current Scheduler account and accessible organizations. Does not require organization ID header.
- `GET /v1/reservations`: reservation list. Defaults to next 14 days for all users in requested organization. Query filters include begin/end timestamps and resource/user style filters.
- `GET /v1/users`: users in current organization.
- `GET /v1/resources`: resources current user can access in current organization.
- `GET /v1/schedules`: schedules in current organization.

Coding notes:

- Scheduler timestamps in endpoint params are integer seconds since Unix epoch.
- `/v1/me` should generally be the first Scheduler call, to discover organization IDs.
- Include `X-LabArchives-OrganizationId` for organization-scoped calls.

## Inventory API

Overview:

- Only version documented: `v1`.
- JSON request/response except attachment endpoints return ZIP archives.
- Authentication uses HMAC-SHA-512 signatures in headers.
- Start with `GET /public/v1/users/me` to discover lab IDs.

Endpoints:

- `GET /public/v1/users/me`: current Inventory user and labs. Ignores lab ID header.
- `GET /public/v1/inventory`: list inventory items for current lab. Max 1000 results per request. Optional filters include search term, type IDs, storage location IDs, and include-out-of-stock behavior.
- `GET /public/v1/inventory/{itemId}`: item detail.
- `GET /public/v1/inventory/{itemId}/attachments`: item attachments as ZIP named `Attachments-{itemId}.zip`.
- `POST /public/v1/inventory`: create item. Required body fields: `name`, `typeId`.
- `POST /public/v1/inventory/{itemId}`: update item. Required body fields: `name`, `typeId`.
- `GET /public/v1/item-types`: item type metadata and custom attributes.
- `GET /public/v1/orders`: list all orders for current lab.
- `GET /public/v1/orders/requested`: requested orders.
- `GET /public/v1/orders/approved`: approved orders.
- `GET /public/v1/orders/ordered`: ordered orders.
- `GET /public/v1/orders/received`: received orders.
- `GET /public/v1/orders/cancelled`: cancelled orders.
- `GET /public/v1/orders/{labOrderId}`: order detail.
- `GET /public/v1/orders/{labOrderId}/attachments`: order attachments as ZIP named `Attachments-{labOrderId}.zip`.
- `POST /public/v1/orders/{labOrderId}/approve`: approve a requested order. Body can include optional `notes`.
- `POST /public/v1/orders/{labOrderId}/order`: place an approved order. Body can include optional `notes`, `price`, `quantity`.
- `POST /public/v1/orders/{labOrderId}/receive`: receive an ordered order. PDF page appears truncated at the request body example; verify before implementing.
- `GET /public/v1/storage-locations`: storage location metadata, including freezer box dimensions/display format.
- `GET /public/v1/vendors`: vendor metadata.

Inventory item body fields seen in create/update examples:

- `name` required.
- `typeId` required.
- `quantityAvailable`, `unit`, `storageLocationId`, `storageLocationNotes`, `storageCells`.
- `expirationDate`, `sendExpirationNotification`, `expirationNotificationDays`.
- `description`, `notes`.
- `catalogNumber`, `grantNumber`, `poNumber`, `lotNumber`.
- `price`, `vendorId`, `dateReceived`, `dateOrdered`.
- `safetySheetUrl`.
- `customAttributes`: list with `id` and `values`.
- `attachments`: examples show attachment metadata in responses; confirm upload semantics before implementing attachment writes.

## Known PDF Extraction Issues

- Page 10 auth table text is visually clipped/truncated in extraction. Use the surrounding examples and Scheduler/Inventory sections for signature specifics.
- Page 206, `POST /public/v1/orders/{labOrderId}/receive`, appears truncated in the PDF itself. It ends around `"notes": "Th`.
- `pdfimages -list` reported only a few images; the document is mostly text with a usable text layer.

## Programming Tips And Traps

Keep this section practical. These are implementation notes that prevent future coding sessions from rediscovering already solved details.

### Attachment Handling

- Use `notebooks::notebook_backup` as the preservation source of truth. `entries::entry_attachment` downloads one current entry file; it is useful for targeted access but is not a replacement for a full notebook backup.
- Request backups with `json=true` and omit `no_attachments=true`. Passing `no_attachments=true` produces a lighter archive but breaks BenchVault's evidence and restore goals because full-size original payloads are absent.
- Attachment metadata is in `extracted/notebook/entry_parts.json`. Rows may be wrapped as `{ "entry_part": { ... } }`, so parse wrapped and unwrapped shapes. Important fields are `id`, `entry_id`, `relative_position`, `entry_data`, `attach_file_name`, `attach_file_size`, and `attach_content_type`.
- For attachment parts, `entry_data` is the caption or surrounding note, not the file contents. Render it as text near the attachment card, but never treat it as the payload.
- Original payloads have been observed under `extracted/notebook/attachments/<entry-part-id>/<version>/original/<filename>`, usually with version `1`. Code should first try the direct path, then recursively search under the entry-part attachment directory for a matching filename inside an `original` segment. This protects the viewer if LabArchives changes the version directory or nesting.
- Verify every non-empty `attach_file_name` before marking a backup complete: locate the original payload, compare byte count against `attach_file_size`, and write SHA-256 plus relative path into `original_files_manifest.json`.
- Fail and discard the partial notebook run if original verification is incomplete. A backup that silently misses originals is worse than no backup because it can mislead the user about preservation quality.
- Store attachment paths relative to the selected backup root in `render_notebook.json`, `readable/notebook.md`, `search_chunks.jsonl`, and manifests. Do not store machine-specific absolute paths in tracked docs, render sidecars, or GitHub-visible examples.
- Restore means copying the backed-up original payload to a user-selected folder, not opening or modifying the backup in place. Sanitize path separators and control characters from attachment names, then add suffixes such as `name (1).ext` to avoid overwriting existing files.
- After restore, compare the copied file size to the backup metadata and delete the restored copy if the size does not match. This catches interrupted copies and path-resolution mistakes.
- Filename edge case observed on May 14, 2026: LabArchives accepted no-extension uploads, but the full notebook backup omitted their `original/` payloads. Keep test fixtures extension-bearing unless deliberately testing that failure mode.

### Attachment Format Support

Current LabArchives help says notebook attachments can be any file type and format, but only some families have direct LabArchives viewers or editors. Sources checked online on May 14, 2026:

- [Attachments](https://help.labarchives.com/hc/en-us/articles/11731752815508-Attachments): arbitrary attachments; direct view for text files, PDFs, Microsoft Office documents, and common images such as PNG, JPG, and GIF; Office view/edit depends on Microsoft Office for the Web and size limits.
- [Image Annotator](https://help.labarchives.com/hc/en-us/articles/11731813005076-Image-Annotator): annotates browser-supported image formats such as JPG, PNG, and GIF; TIFF is specifically not browser-native.
- [Jupyter Integration](https://help.labarchives.com/hc/en-us/articles/11780569021972-Jupyter-Integration): `.ipynb` files render in the LabArchives Docs Viewer.
- [SnapGene Integration](https://help.labarchives.com/hc/en-us/articles/11780512729492-SnapGene-Integration): sequence/project formats include `.dna`, `.seq`, `.xdna`, `.clc`, `.pdw`, `.cx5`, `.cm5`, `.nucl`, `.gcproj`, `.cow`, `.embl`, `.gcc`, `.fasta`, `.fa`, `.gb`, `.gbk`, `.sbd`, and `.geneious`.
- [Inventory item attachments](https://help.labarchives.com/hc/en-us/articles/11809875199252-Adding-an-Inventory-Item): inventory attachment examples include PDFs, text/images, chemical formats `.cdx`, `.cdxml`, `.mol`, `.sdf`, `.skc`, and DNA sequence formats including `.ab1`.

Viewer implementation rules:

- Preserve and restore every original payload regardless of extension. LabArchives' broad "any file type" rule means unknown instrument formats must be first-class preservation objects, not errors.
- Inline-preview only formats that Flutter can render safely without executing active content: common raster images, text/tabular/structured files, sequence text, text-based chemical files, and Jupyter summaries parsed from the `.ipynb` JSON.
- Treat HTML and SVG attachments as source text in the read-only viewer. Do not run scripts, remote resources, or embedded active content from a backup.
- Recognize PDF, Office, TIFF, SnapGene/Geneious/Sanger trace, binary chemical drawings, media, archives, and unknown formats with clear metadata and restore affordances. These remain sealed originals and should be opened in an appropriate local tool if visual inspection is needed.
- Keep format classification in `lib/src/attachment_format_support.dart` so future renderer improvements do not spread extension rules across UI code.

### Backup And Viewer Data Flow

- Backup flow: download `notebook.7z`, extract to `extracted/`, parse JSON tables into `render_notebook.json`, verify originals into `original_files_manifest.json`, write readable/search sidecars, then seal integrity.
- Viewer flow should prefer `render_notebook.json` for speed and consistency. If older records lack attachment original paths, resolve from the render file's run directory using the observed `extracted/notebook/attachments/<part-id>/.../original/<filename>` pattern.
- `readable/notebook.md` is for human and model-readable review. It should include page paths, part IDs, attachment names, metadata, relative original payload paths, and comments.
- `readable/search_chunks.jsonl` is for natural-language search. Keep each chunk bounded in size and include attachment summary strings so users can ask for records by assay type, instrument file name, or payload format.
- Keep faithful archives and readable sidecars separate. The `.7z` archive plus extracted originals are the preservation copy; Markdown/JSONL are convenience indexes generated from the backup.

### Search Fallback

- OpenAI search should be treated as an enhancement, not a dependency. Always build local readable/search sidecars first so search still works without an API key, during network outages, or when the OpenAI request returns an error.
- Local fallback currently ranks chunks with a hybrid lexical/fuzzy method: BM25-style term relevance, exact phrase boosts, title/path/attachment field boosts, typo-tolerant token similarity using edit distance, and character n-gram containment. This is deliberately on-device and deterministic.
- On OpenAI failure, return the local fuzzy results with a warning rather than surfacing a hard failure. The user should still get the top pages and snippets, and the warning should make clear that the answer is local fallback output.
- Keep OpenAI context tight: send only top-ranked excerpts, attachment summaries, page paths, notebook names, and backup timestamps. Never send credentials, raw archives, local absolute paths, or unrelated notebook material.
- Public screenshots for AI search must use demo data only. They may show the natural-language answer surface and local fallback availability, but should not expose real notebook names, IDs, paths, credentials, or raw backup contents.

### Parsing And Rendering

- The JSON export is table-like. Build maps by IDs rather than assuming file order: `tree_nodes.json` defines notebook structure, `entries.json` links pages to entries, `entry_parts.json` holds ordered parts, and `comments.json` links comments to `entry_part_id`.
- Sort entry parts by `relative_position` before rendering. Sort comments by creation time so the read-only view matches normal notebook reading order.
- Rich text can contain links. Convert anchors to `label (URL)` before stripping remaining HTML so external data-storage links are not lost.
- Treat unknown part types conservatively: preserve the part ID, label it as an unknown entry part, and render any text that can be safely extracted.

### Integrity And Evidence

- Integrity sealing is tamper-evidence, not legal certification. Hash every protected run file except the integrity manifest itself, then record the manifest hash in the ignored local ledger.
- The viewer should warn loudly if any protected file changes after backup. Do not attempt to repair or normalize protected files during verification because that would change the evidence surface.
- Keep credentials, UID files, OpenAI keys, source PDFs, raw downloaded notebooks, and integrity ledgers in macOS Keychain or ignored local paths. Only placeholder templates and relative-path examples belong in Git.

## Living Implementation Notes

Append notes here as coding work reveals practical behavior.

- Prefer typed request builders for signatures so method-path rules are encoded once per product.
- Keep ELN, Scheduler, and Inventory auth helpers separate. Their signature method string and hash algorithm differ.
- ELN credential-auth smoke test confirmed on May 14, 2026: `utilities::promo_message` returned HTTP 200 using Base64 HMAC-SHA1 over `<akid>promo_message<expires>`, with the access password as the HMAC key.
- Credential-authenticated utility calls can prove the access key works, but writing `helloworld` as an ELN entry requires additional user/notebook/page context: `uid`, `nbid`, and `pid`.
- Local auth helper: `scripts/labarchives_auth_flow.py` opens the LabArchives API login URL via a localhost callback, exchanges `auth_code` with `users::user_access_info`, and saves raw XML under ignored `local_credentials/`.
- The app first-run setup uses the same signed `/api_user_login` flow. If a platform cannot open/catch the localhost callback cleanly, the manual fallback is to paste the returned `auth_code` and exchange it with `users::user_access_info`.
- `users::user_access_info` response uses top-level `<id>` for the API `uid`; each `<notebooks><notebook>` contains notebook `<id>` values used as `nbid`.
- `tree_tools::get_tree_level` response uses `<level-nodes><level-node>`. Each node has `<tree-id>`, `<display-text>`, and `<is-page>`. A node with `<is-page>true</is-page>` can be used as `pid` for `entries::add_entry`.
- ELN write smoke test confirmed on May 14, 2026: `entries::add_entry` with `part_type=plain text entry` and `entry_data=helloworld` returned HTTP 200 and an entry ID on a test notebook page.
- `notebooks::notebook_backup` returns a `.7z` archive. With `json=true`, useful viewer inputs include `notebook.json`, `user.json`, `widgets.json`, and JSON tables under `notebook/`, especially `tree_nodes.json`, `entries.json`, `entry_parts.json`, and `comments.json`.
- BenchVault backup storage convention: the user-selected backup folder contains `notebooks/<notebook>/<year>/<month>/<day>/<run>/` for archives, extracted JSON, render sidecars, and per-notebook records; `runs/<year>/<month>/<day>/` stores run manifests.
- Readable/search sidecar convention: each successful backup run also contains `readable/notebook.md` and `readable/search_chunks.jsonl`. These are derived from `render_notebook.json`, use backup-folder-relative attachment paths, and are regenerated for older backups on first search if missing.
- Integrity seal convention: after the archive, extracted files, render JSON, readable sidecars, original manifest, and backup record are written, create `integrity_manifest.json` with SHA-256 hashes for every protected backup-run file except the integrity manifest itself. Append the manifest hash to ignored `local_credentials/integrity_ledger.jsonl` as a local hash-chain ledger. The viewer verifies both the file hashes and the local seal before displaying the backup status; this is tamper-evidence, not a standalone legal certification.
- NIH visual convention: use an NIH/HHS-aligned blue-first palette for the app and public assets. Primary blue `#005ea2`, dark blue `#162e51`, light blue `#e5faff`, gold accent `#face00`, and cool neutral surfaces keep the app close to the NIH/HHS web environment while preserving semantic status colors.
- OpenAI search credential convention: on macOS app launches, store `OPENAI_API_KEY` in Keychain and keep only non-secret model metadata in ignored `local_credentials/openai.env`; fallback/test paths may store both values in the ignored file. The app defaults the model to `gpt-5.5` and sends only the locally selected notebook excerpts needed for a natural-language answer.
- Search filter convention: keep search filters local and deterministic before
  OpenAI context selection. `All`, `Text`, `Files`, `Comments`, exact phrase,
  and verified-only filters narrow the local chunk corpus first; OpenAI only sees
  the filtered top-ranked excerpts.
- Full-size original-content rule: never pass `no_attachments=true` to `notebooks::notebook_backup`. For every attachment in `entry_parts.json`, verify `notebook/attachments/<entry-part-id>/<version>/original/<filename>` exists and matches `attach_file_size`; write `original_files_manifest.json` with relative paths, sizes, and SHA-256 hashes.
- Viewer restore rule: render sidecars include each attachment original's backup-relative path when the original file is present. The read-only viewer restores attachments by copying that original payload to a user-selected folder without overwriting existing files; legacy render files fall back to `extracted/notebook/attachments/<entry-part-id>/.../original/<filename>`.
- Viewer attachment format rule: LabArchives allows arbitrary notebook attachments, with direct/cloud viewers for text, PDF, Office, common browser images, Jupyter `.ipynb`, and SnapGene/sequence families. BenchVault should preserve every original payload, inline-preview safe local formats, treat HTML/SVG as source text, and classify Office/PDF/SnapGene/TIFF/chemical/media/archive/custom files with restore-first affordances until dedicated renderers are added.
- Viewer comment/link rule: parse `comments.json` by `entry_part_id` and render comments beneath their entry part. Convert HTML anchors to readable `label (URL)` text before stripping remaining HTML so link targets are not silently lost in the read-only view.
- Viewer navigation convention: derive breadcrumbs and page outlines from
  `tree_nodes.json` parent IDs and `entry_parts.json` relative positions. Treat
  them as navigation aids only; do not infer legal provenance from those UI
  affordances.
- Audit export convention: write local review sidecars under each run's `audit/`
  folder: `backup_audit_summary.md`, `backup_audit_summary.json`,
  `integrity_files.csv`, and `external_hash_anchor.txt`. Exclude `audit/` from
  protected-file verification so creating an audit packet does not make a sealed
  backup appear modified.
- Backup rights are stricter than notebook visibility. On May 14, 2026, visible non-owned notebooks returned ELN error `4547` with "does not have rights to perform requested action"; the app treats these as skipped notebooks during "backup all owned/backup-allowed notebooks."
- NIH/NICHD policy context: lab notebook owners are lab chiefs/PIs, and only the notebook owner can use the full-size LabArchives backup API for that notebook. Users who can view a notebook but are not the PI owner should expect backup API denial.
- Dedicated integration notebook seeded on May 14, 2026 with headings, rich text, plain text, comments, folders/pages, and bio-lab attachments covering CSV, TSV, FASTA, VCF, BED, GenBank, JSON, XML, Markdown, HTML, notebook, SVG, TXT, PDF, and PNG payloads.
- Expanded NICHD storyline seed on May 14, 2026: `scripts/labarchives_seed_bio_test_notebook.py` now reuses the local integration notebook by default and adds a dated "NICHD Model Systems Lab Storyline" subtree. The seed creates 35 pages organized around a hypoxia/interferon developmental-stress hypothesis, with standard audit headers, sample accession/provenance/control records, zebrafish and mouse model pages, reproductive and placental systems, chemical biology, physical molecular biophysics, omics, shared-core instruments, QA/preservation, and archive payload pages. The generated run includes 97 shared fixture files plus one page-specific audit attachment per page, for 132 expected attachment uploads, including vendor-shaped placeholders, duplicate/weird filenames, a documented no-extension backup limitation using a `.txt` fixture, a zip stub, and a moderately large binary payload. Generated payload files and returned IDs stay under ignored `local_credentials/`. This helper is intentionally write-capable and now refuses to contact LabArchives write endpoints unless both the explicit acknowledgement flag and environment guard are present.
- No-extension attachment limitation observed on May 14, 2026: LabArchives accepted no-extension uploads named `RAW_EXPORT` and `README_NO_EXTENSION`, but `notebooks::notebook_backup` omitted their `original/` payloads, causing BenchVault verification to fail with 267/271 originals. The seed now uses suffixed versions so the clean testing notebook can pass full-size backup verification.
- Keep UID, organization ID, and lab ID discovery calls explicit:
  - ELN: `user_access_info` or `user_info_via_id`.
  - Scheduler: `GET /v1/me`.
  - Inventory: `GET /public/v1/users/me`.
- For ELN uploads, do not use common multipart upload helpers unless they can send the file as the entire raw request body with `Content-Type: application/octet-stream`.
- Treat 404 from search/existence paths as empty result, but do not apply that rule globally to detail endpoints without checking context.
