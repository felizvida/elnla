# LabArchives GOV API Working Reference

Source PDF:
`/Users/liux17/Library/CloudStorage/OneDrive-NationalInstitutesofHealth/CSSC/ELNs/2026_05_14_notebook_70221.pdf`

Generated from: LabArchives GOV API Complete Notebook, generated May 14, 2026 at 03:30 PM EDT.

Purpose: compact working notes for future coding. Use this first before reopening the 210-page PDF. Enrich this file whenever implementation work uncovers more details, hidden API behavior, or useful coding patterns.

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

## Living Implementation Notes

Append notes here as coding work reveals practical behavior.

- Prefer typed request builders for signatures so method-path rules are encoded once per product.
- Keep ELN, Scheduler, and Inventory auth helpers separate. Their signature method string and hash algorithm differ.
- Keep UID, organization ID, and lab ID discovery calls explicit:
  - ELN: `user_access_info` or `user_info_via_id`.
  - Scheduler: `GET /v1/me`.
  - Inventory: `GET /public/v1/users/me`.
- For ELN uploads, do not use common multipart upload helpers unless they can send the file as the entire raw request body with `Content-Type: application/octet-stream`.
- Treat 404 from search/existence paths as empty result, but do not apply that rule globally to detail endpoints without checking context.
