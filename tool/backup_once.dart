import 'dart:io';

import 'package:elnla/src/backup_service.dart';

Future<void> main() async {
  final service = BackupService();
  final records = await service.backupAllNotebooks(onProgress: stdout.writeln);
  stdout.writeln('created=${records.length}');
  for (final record in records) {
    stdout.writeln(
      '${record.notebookName}\t${record.pageCount}\t${record.renderPath}',
    );
  }
}
