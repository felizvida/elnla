import 'dart:convert';
import 'dart:io';

import 'package:benchvault/src/backup_models.dart';
import 'package:benchvault/src/backup_service.dart';
import 'package:benchvault/src/notebook_search_service.dart';
import 'package:benchvault/src/preflight_models.dart';
import 'package:benchvault/src/search_models.dart';
import 'package:benchvault/src/setup_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('backup settings persist schedule and selected backup root', () async {
    final root = await Directory.systemTemp.createTemp(
      'benchvault_settings_test_',
    );
    addTearDown(() => root.delete(recursive: true));

    final service = BackupService(root: root);
    final backupRoot = Directory('${root.path}/routine_copies');
    final settings = BackupSettings(
      backupRootPath: backupRoot.path,
      schedule: const BackupSchedule(
        enabled: true,
        frequency: BackupFrequency.weekly,
        minutesAfterMidnight: 7 * 60 + 15,
        weekday: DateTime.thursday,
      ),
    );

    await service.saveBackupSettings(settings);
    final loaded = await service.loadBackupSettings();

    expect(loaded.backupRootPath, backupRoot.path);
    expect(loaded.schedule.enabled, isTrue);
    expect(loaded.schedule.frequency, BackupFrequency.weekly);
    expect(loaded.schedule.minutesAfterMidnight, 7 * 60 + 15);
    expect(loaded.schedule.weekday, DateTime.thursday);
  });

  test('preflight blocks backup when setup files are missing', () async {
    final root = await Directory.systemTemp.createTemp(
      'benchvault_preflight_missing_test_',
    );
    addTearDown(() => root.delete(recursive: true));

    final report = await BackupService(root: root).runPreflight();
    final credentials = report.checks.firstWhere(
      (check) => check.id == 'credentials',
    );
    final notebookIndex = report.checks.firstWhere(
      (check) => check.id == 'notebook_index',
    );

    expect(report.canRunBackup, isFalse);
    expect(credentials.status, PreflightStatus.fail);
    expect(notebookIndex.status, PreflightStatus.fail);
  });

  test('preflight reports ready local setup and read-only contract', () async {
    final root = await Directory.systemTemp.createTemp(
      'benchvault_preflight_ready_test_',
    );
    addTearDown(() => root.delete(recursive: true));

    final local = Directory('${root.path}/local_credentials');
    await local.create(recursive: true);
    await File('${local.path}/labarchives.env').writeAsString(
      'LABARCHIVES_GOV_LOGIN_ID=fake\nLABARCHIVES_GOV_ACCESS_KEY=fake\n',
    );
    await File(
      '${local.path}/labarchives_user.env',
    ).writeAsString('LABARCHIVES_GOV_UID=fake_uid\n');
    await File(
      '${local.path}/notebooks.tsv',
    ).writeAsString('name\tnbid\tis_default\nDemo\tfake_nbid\ttrue\n');

    final service = BackupService(root: root);
    await service.saveBackupSettings(
      BackupSettings.defaults('${root.path}/routine_backups'),
    );

    final report = await service.runPreflight();
    final credentials = report.checks.firstWhere(
      (check) => check.id == 'credentials',
    );
    final notebookIndex = report.checks.firstWhere(
      (check) => check.id == 'notebook_index',
    );
    final readOnly = report.checks.firstWhere(
      (check) => check.id == 'read_only_contract',
    );
    final backupFolder = report.checks.firstWhere(
      (check) => check.id == 'backup_folder',
    );

    expect(credentials.status, PreflightStatus.pass);
    expect(notebookIndex.status, PreflightStatus.pass);
    expect(readOnly.status, PreflightStatus.pass);
    expect(backupFolder.status, PreflightStatus.pass);
    expect(
      report.blockingChecks.map((check) => check.id),
      isNot(contains('credentials')),
    );
    expect(
      report.blockingChecks.map((check) => check.id),
      isNot(contains('notebook_index')),
    );
  });

  test('latest backup run manifest preserves outcomes and log', () async {
    final root = await Directory.systemTemp.createTemp(
      'benchvault_run_manifest_test_',
    );
    addTearDown(() => root.delete(recursive: true));

    final runDir = Directory('${root.path}/backups/runs/2026/05/14');
    await runDir.create(recursive: true);
    final record = BackupRecord(
      id: 'run_001_demo',
      notebookName: 'Demo',
      createdAt: DateTime.utc(2026, 5, 14, 12),
      archivePath: 'notebooks/demo/2026/05/14/run_001/notebook.7z',
      renderPath: 'notebooks/demo/2026/05/14/run_001/render_notebook.json',
      pageCount: 3,
      contentVerification: const BackupContentVerification(
        archiveBytes: 900,
        expectedOriginalAttachmentCount: 2,
        verifiedOriginalAttachmentCount: 2,
        expectedOriginalAttachmentBytes: 700,
        verifiedOriginalAttachmentBytes: 700,
        manifestPath:
            'notebooks/demo/2026/05/14/run_001/original_files_manifest.json',
        missingOriginals: [],
        sizeMismatches: [],
      ),
    );
    final manifest = BackupRunManifest(
      id: 'run_001',
      createdAt: DateTime.utc(2026, 5, 14, 12),
      completedAt: DateTime.utc(2026, 5, 14, 12, 2),
      totalNotebookCount: 2,
      records: [record],
      outcomes: [
        BackupNotebookOutcome(
          notebookName: 'Demo',
          status: BackupOutcomeStatus.success,
          category: BackupFailureCategory.none,
          message: 'Backed up successfully.',
          backupRecordId: record.id,
          pageCount: record.pageCount,
          archiveBytes: 900,
          verifiedOriginalAttachmentCount: 2,
          expectedOriginalAttachmentCount: 2,
        ),
        const BackupNotebookOutcome(
          notebookName: 'Visible but not owned',
          status: BackupOutcomeStatus.skipped,
          category: BackupFailureCategory.notOwner,
          message: 'Full-size backup is owner-only for this notebook.',
          nextAction: 'Ask the PI owner to run the backup.',
        ),
      ],
      log: const ['Finished Demo', 'Skipped Visible but not owned'],
    );
    await File('${runDir.path}/run_001.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
    );

    final loaded = await BackupService(root: root).loadLatestBackupRun();

    expect(loaded, isNotNull);
    expect(loaded!.successCount, 1);
    expect(loaded.skippedCount, 1);
    expect(loaded.totalNotebookCount, 2);
    expect(loaded.outcomes.last.category, BackupFailureCategory.notOwner);
    expect(loaded.log, contains('Finished Demo'));
  });

  test(
    'restoreAttachment copies backed-up original without overwriting',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'benchvault_restore_test_',
      );
      addTearDown(() => root.delete(recursive: true));

      final service = BackupService(root: root);
      final runDir = Directory(
        '${root.path}/backups/notebooks/demo/2026/05/14/run_001',
      );
      final originalDir = Directory(
        '${runDir.path}/extracted/notebook/attachments/3/1/original',
      );
      await originalDir.create(recursive: true);
      final original = File('${originalDir.path}/raw/image.tif');
      await Directory('${originalDir.path}/raw').create(recursive: true);
      await original.writeAsBytes([1, 2, 3, 4]);

      final render = File('${runDir.path}/render_notebook.json');
      await render.writeAsString('{}');
      final record = BackupRecord(
        id: 'run_001_demo',
        notebookName: 'Demo',
        createdAt: DateTime.utc(2026, 5, 14),
        archivePath: 'notebooks/demo/2026/05/14/run_001/notebook.7z',
        renderPath: 'notebooks/demo/2026/05/14/run_001/render_notebook.json',
        pageCount: 1,
      );
      final part = RenderPart(
        id: 3,
        kindCode: 2,
        kindLabel: 'Attachment',
        renderText: 'caption',
        position: 1,
        attachmentName: 'raw/image.tif',
        attachmentSize: 4,
        attachmentOriginalPath:
            'notebooks/demo/2026/05/14/run_001/extracted/notebook/attachments/3/1/original/raw/image.tif',
      );
      final destination = Directory('${root.path}/restored');
      await destination.create();
      await File('${destination.path}/raw_image.tif').writeAsBytes([9]);

      final restored = await service.restoreAttachment(
        record: record,
        part: part,
        destination: destination,
      );

      expect(restored.path.endsWith('raw_image (1).tif'), isTrue);
      expect(await restored.readAsBytes(), [1, 2, 3, 4]);
    },
  );

  test('loadAttachmentTextPreview reads safe bounded text only', () async {
    final root = await Directory.systemTemp.createTemp(
      'benchvault_preview_test_',
    );
    addTearDown(() => root.delete(recursive: true));

    final service = BackupService(root: root);
    final originalDir = Directory(
      '${root.path}/backups/notebooks/demo/2026/05/14/run_004/extracted/notebook/attachments/4/1/original',
    );
    await originalDir.create(recursive: true);
    await File(
      '${originalDir.path}/amplicon.fasta',
    ).writeAsString('>amplicon\nACGTACGTACGT\n');
    await File('${originalDir.path}/trace.ab1').writeAsBytes([65, 0, 66]);
    final record = BackupRecord(
      id: 'run_004_demo',
      notebookName: 'Demo',
      createdAt: DateTime.utc(2026, 5, 14),
      archivePath: 'notebooks/demo/2026/05/14/run_004/notebook.7z',
      renderPath: 'notebooks/demo/2026/05/14/run_004/render_notebook.json',
      pageCount: 1,
    );

    final preview = await service.loadAttachmentTextPreview(
      record: record,
      part: const RenderPart(
        id: 4,
        kindCode: 2,
        kindLabel: 'Attachment',
        renderText: '',
        position: 1,
        attachmentName: 'amplicon.fasta',
        attachmentOriginalPath:
            'notebooks/demo/2026/05/14/run_004/extracted/notebook/attachments/4/1/original/amplicon.fasta',
      ),
      maxBytes: 12,
    );
    expect(preview, startsWith('>amplicon'));
    expect(preview, contains('[Preview truncated]'));

    final binaryPreview = await service.loadAttachmentTextPreview(
      record: record,
      part: const RenderPart(
        id: 4,
        kindCode: 2,
        kindLabel: 'Attachment',
        renderText: '',
        position: 1,
        attachmentName: 'trace.ab1',
        attachmentOriginalPath:
            'notebooks/demo/2026/05/14/run_004/extracted/notebook/attachments/4/1/original/trace.ab1',
      ),
    );
    expect(binaryPreview, isNull);
  });

  test('OpenAI search settings stay in local credentials', () async {
    final root = await Directory.systemTemp.createTemp(
      'benchvault_openai_test_',
    );
    addTearDown(() => root.delete(recursive: true));

    final service = BackupService(root: root);
    await service.saveOpenAiSearchSettings(
      const OpenAiSearchSettings(
        apiKey: 'test-openai-local-only',
        model: 'gpt-5.5',
      ),
    );

    final loaded = await service.loadOpenAiSearchSettings();
    expect(loaded?.apiKey, 'test-openai-local-only');
    expect(loaded?.model, 'gpt-5.5');
    expect(
      await File('${root.path}/local_credentials/openai.env').exists(),
      isTrue,
    );

    await service.saveOpenAiSearchSettings(
      const OpenAiSearchSettings(apiKey: ''),
    );
    expect(await service.loadOpenAiSearchSettings(), isNull);
  });

  test('readable copy and local search are generated from render JSON', () async {
    final root = await Directory.systemTemp.createTemp(
      'benchvault_readable_test_',
    );
    addTearDown(() => root.delete(recursive: true));

    final service = BackupService(root: root);
    final runDir = Directory(
      '${root.path}/backups/notebooks/demo_lab/2026/05/14/run_002',
    );
    await runDir.create(recursive: true);
    final notebook = RenderNotebook(
      name: 'Demo Lab Notebook',
      createdAt: DateTime.utc(2026, 5, 14),
      archivePath: 'notebooks/demo_lab/2026/05/14/run_002/notebook.7z',
      nodes: const [
        RenderNode(
          id: 1,
          parentId: 0,
          title: 'NICHD Storyline',
          isPage: false,
          position: 1,
          parts: [],
        ),
        RenderNode(
          id: 2,
          parentId: 1,
          title: 'Zebrafish hypoxia assay',
          isPage: true,
          position: 1,
          parts: [
            RenderPart(
              id: 10,
              kindCode: 1,
              kindLabel: 'Rich text',
              renderText:
                  'Zebrafish embryos were exposed to hypoxia and imaged for developmental stress markers.',
              position: 1,
              comments: [
                RenderComment(
                  id: 99,
                  text: 'PI requested repeat imaging on the Zeiss microscope.',
                  createdAt: '2026-05-14T12:00:00Z',
                  author: 'QA reviewer',
                ),
              ],
            ),
            RenderPart(
              id: 11,
              kindCode: 2,
              kindLabel: 'Attachment',
              renderText: 'Raw imaging export',
              position: 2,
              attachmentName: 'zebrafish_image.czi',
              attachmentContentType: 'application/octet-stream',
              attachmentSize: 12,
              attachmentOriginalPath:
                  'notebooks/demo_lab/2026/05/14/run_002/extracted/notebook/attachments/11/1/original/zebrafish_image.czi',
            ),
          ],
        ),
      ],
    );
    await File(
      '${runDir.path}/render_notebook.json',
    ).writeAsString(notebook.toPrettyJson());
    final record = BackupRecord(
      id: 'run_002_demo_lab',
      notebookName: 'Demo Lab Notebook',
      createdAt: DateTime.utc(2026, 5, 14),
      archivePath: 'notebooks/demo_lab/2026/05/14/run_002/notebook.7z',
      renderPath: 'notebooks/demo_lab/2026/05/14/run_002/render_notebook.json',
      pageCount: 1,
    );
    await File('${runDir.path}/backup_record.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(record.toJson()),
    );

    final updated = await service.ensureReadableCopy(record);
    expect(updated.readablePath, isNot(startsWith(root.path)));
    expect(updated.searchIndexPath, isNot(startsWith(root.path)));

    final markdown = await File(
      '${root.path}/backups/${updated.readablePath}',
    ).readAsString();
    expect(markdown, contains('Zebrafish hypoxia assay'));
    expect(markdown, contains('zebrafish_image.czi'));

    final chunks = await service.loadSearchChunks(updated);
    expect(chunks, hasLength(1));
    expect(chunks.single.text, contains('hypoxia'));
    expect(chunks.single.attachments.single, contains('zebrafish_image.czi'));

    final result = await NotebookSearchService(
      service,
    ).search('Where is zebrafish hypoxia imaging described?');
    expect(result.usedOpenAi, isFalse);
    expect(result.hits.single.chunk.pageTitle, 'Zebrafish hypoxia assay');

    final fuzzyResult = await NotebookSearchService(
      service,
    ).search('zebrafsh Zeis microscop raw imgng');
    expect(fuzzyResult.usedOpenAi, isFalse);
    expect(fuzzyResult.hits.single.chunk.pageTitle, 'Zebrafish hypoxia assay');
    expect(fuzzyResult.answer, contains('Local fuzzy search'));

    final attachmentResult = await NotebookSearchService(service).search(
      'zebrafish_image.czi',
      filters: const NotebookSearchFilters(
        scope: NotebookSearchScope.attachments,
        exactPhrase: true,
      ),
    );
    expect(
      attachmentResult.hits.single.chunk.attachments.single,
      contains('.czi'),
    );
    expect(attachmentResult.filters.scope, NotebookSearchScope.attachments);

    final verifiedOnlyResult = await NotebookSearchService(service).search(
      'zebrafish',
      filters: const NotebookSearchFilters(verifiedOnly: true),
    );
    expect(verifiedOnlyResult.hits, isEmpty);
    expect(verifiedOnlyResult.answer, contains('selected search filters'));
  });

  test('integrity seal detects byte-level backup changes', () async {
    final root = await Directory.systemTemp.createTemp(
      'benchvault_integrity_test_',
    );
    addTearDown(() => root.delete(recursive: true));

    final service = BackupService(root: root);
    final runDir = Directory(
      '${root.path}/backups/notebooks/demo/2026/05/14/run_003',
    );
    await runDir.create(recursive: true);
    await File('${runDir.path}/notebook.7z').writeAsBytes([1, 2, 3]);
    await File('${runDir.path}/render_notebook.json').writeAsString(
      jsonEncode({
        'name': 'Integrity Demo',
        'createdAt': DateTime.utc(2026, 5, 14).toIso8601String(),
        'archivePath': 'notebooks/demo/2026/05/14/run_003/notebook.7z',
        'nodes': <Object?>[],
      }),
    );
    await Directory('${runDir.path}/readable').create();
    await File(
      '${runDir.path}/readable/notebook.md',
    ).writeAsString('# Integrity Demo\n');

    final record = BackupRecord(
      id: 'run_003_demo',
      notebookName: 'Integrity Demo',
      createdAt: DateTime.utc(2026, 5, 14),
      archivePath: 'notebooks/demo/2026/05/14/run_003/notebook.7z',
      renderPath: 'notebooks/demo/2026/05/14/run_003/render_notebook.json',
      readablePath: 'notebooks/demo/2026/05/14/run_003/readable/notebook.md',
      pageCount: 0,
    );

    final sealed = await service.sealBackupIntegrity(record);
    final verified = await service.verifyBackupIntegrity(sealed);
    expect(sealed.integrityManifestPath, isNotNull);
    expect(verified.isVerified, isTrue);
    expect(verified.checkedFileCount, greaterThanOrEqualTo(3));

    await File('${runDir.path}/notebook.7z').writeAsBytes([1, 2, 4]);
    final tampered = await service.verifyBackupIntegrity(sealed);
    expect(tampered.isVerified, isFalse);
    expect(tampered.changedFiles, contains(sealed.archivePath));
    expect(tampered.statusTitle, 'Backup contents changed');
  });

  test(
    'audit export writes markdown json and csv with relative paths',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'benchvault_audit_export_test_',
      );
      addTearDown(() => root.delete(recursive: true));

      final service = BackupService(root: root);
      final runDir = Directory(
        '${root.path}/backups/notebooks/demo/2026/05/14/run_004',
      );
      await runDir.create(recursive: true);
      await File('${runDir.path}/notebook.7z').writeAsBytes([4, 5, 6]);
      await File('${runDir.path}/render_notebook.json').writeAsString(
        jsonEncode({
          'name': 'Audit Demo',
          'createdAt': DateTime.utc(2026, 5, 14).toIso8601String(),
          'archivePath': 'notebooks/demo/2026/05/14/run_004/notebook.7z',
          'nodes': <Object?>[],
        }),
      );
      final record = BackupRecord(
        id: 'run_004_demo',
        notebookName: 'Audit Demo',
        createdAt: DateTime.utc(2026, 5, 14),
        archivePath: 'notebooks/demo/2026/05/14/run_004/notebook.7z',
        renderPath: 'notebooks/demo/2026/05/14/run_004/render_notebook.json',
        pageCount: 0,
        contentVerification: const BackupContentVerification(
          archiveBytes: 3,
          expectedOriginalAttachmentCount: 0,
          verifiedOriginalAttachmentCount: 0,
          expectedOriginalAttachmentBytes: 0,
          verifiedOriginalAttachmentBytes: 0,
          manifestPath:
              'notebooks/demo/2026/05/14/run_004/original_files_manifest.json',
          missingOriginals: [],
          sizeMismatches: [],
        ),
      );

      final sealed = await service.sealBackupIntegrity(record);
      final audit = await service.exportAuditSummary(sealed);

      expect(audit.markdownPath, isNot(startsWith(root.path)));
      expect(audit.jsonPath, isNot(startsWith(root.path)));
      expect(audit.csvPath, isNot(startsWith(root.path)));
      expect(audit.hashAnchorPath, isNot(startsWith(root.path)));
      expect(audit.integrityCheck.isVerified, isTrue);
      expect(
        await File('${root.path}/backups/${audit.markdownPath}').readAsString(),
        contains('BenchVault Backup Audit Summary'),
      );
      expect(
        await File('${root.path}/backups/${audit.csvPath}').readAsString(),
        contains('path,bytes,sha256,modifiedAt'),
      );
      expect(
        await File(
          '${root.path}/backups/${audit.hashAnchorPath}',
        ).readAsString(),
        contains('Manifest SHA-256'),
      );

      final afterExport = await service.verifyBackupIntegrity(sealed);
      expect(afterExport.isVerified, isTrue);
    },
  );
}
