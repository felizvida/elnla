import 'dart:io';

import 'package:benchvault/src/backup_models.dart';
import 'package:benchvault/src/backup_service.dart';

Future<void> main(List<String> args) async {
  final count = _countArg(args);
  final destination = args.length > 1
      ? Directory(args[1])
      : await Directory.systemTemp.createTemp(
          'benchvault_restored_attachments_',
        );
  final service = BackupService();
  final backups = await service.loadBackups();
  if (backups.isEmpty) {
    throw StateError('No local backups found.');
  }
  final backup = backups.firstWhere(
    (record) =>
        record.contentVerification?.expectedOriginalAttachmentCount != 0,
    orElse: () => backups.first,
  );
  final notebook = await service.loadRenderNotebook(backup);
  final attachments = _attachments(notebook).take(count).toList();
  if (attachments.isEmpty) {
    throw StateError('No attachment parts found in ${backup.notebookName}.');
  }
  stdout.writeln('backup=${backup.notebookName}');
  stdout.writeln('destination=${destination.path}');
  for (final part in attachments) {
    final restored = await service.restoreAttachment(
      record: backup,
      part: part,
      destination: destination,
    );
    stdout.writeln(
      '${part.attachmentName}\t${await restored.length()}\t${restored.path}',
    );
  }
}

int _countArg(List<String> args) {
  if (args.isEmpty) {
    return 5;
  }
  final count = int.tryParse(args.first);
  if (count == null || count < 1) {
    throw ArgumentError('First argument must be a positive restore count.');
  }
  return count;
}

Iterable<RenderPart> _attachments(RenderNotebook notebook) sync* {
  for (final node in notebook.nodes) {
    for (final part in node.parts) {
      if (part.isAttachment) {
        yield part;
      }
    }
  }
}
