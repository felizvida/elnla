import 'dart:convert';
import 'dart:io';

import 'package:elnla/src/backup_models.dart';
import 'package:elnla/src/backup_service.dart';
import 'package:elnla/src/notebook_search_service.dart';
import 'package:elnla/src/search_models.dart';
import 'package:elnla/src/setup_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('backup settings persist schedule and selected backup root', () async {
    final root = await Directory.systemTemp.createTemp('elnla_settings_test_');
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

  test(
    'restoreAttachment copies backed-up original without overwriting',
    () async {
      final root = await Directory.systemTemp.createTemp('elnla_restore_test_');
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

  test('OpenAI search settings stay in local credentials', () async {
    final root = await Directory.systemTemp.createTemp('elnla_openai_test_');
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
    final root = await Directory.systemTemp.createTemp('elnla_readable_test_');
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
  });
}
