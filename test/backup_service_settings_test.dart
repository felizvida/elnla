import 'dart:io';

import 'package:elnla/src/backup_models.dart';
import 'package:elnla/src/backup_service.dart';
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
}
