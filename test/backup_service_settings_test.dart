import 'dart:io';

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
}
