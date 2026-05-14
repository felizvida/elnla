import 'dart:convert';
import 'dart:io';

import 'package:elnla/src/backup_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses LabArchives JSON backup tables into render nodes', () async {
    final dir = await Directory.systemTemp.createTemp('elnla_parser_test_');
    addTearDown(() => dir.delete(recursive: true));
    await Directory('${dir.path}/notebook').create(recursive: true);
    await File('${dir.path}/notebook.json').writeAsString(
      jsonEncode({
        'notebook': {'name': 'Parser Test Notebook'},
      }),
    );
    await File('${dir.path}/notebook/tree_nodes.json').writeAsString(
      jsonEncode([
        {
          'tree_node': {
            'id': 10,
            'parent_id': 0,
            'entry_id': null,
            'display_text': 'Assays',
            'relative_position': 1.0,
          },
        },
        {
          'tree_node': {
            'id': 11,
            'parent_id': 10,
            'entry_id': 22,
            'display_text': null,
            'relative_position': 1.0,
          },
        },
      ]),
    );
    await File('${dir.path}/notebook/entries.json').writeAsString(
      jsonEncode([
        {
          'entry': {'id': 22, 'tree_id': 11},
        },
      ]),
    );
    await File('${dir.path}/notebook/entry_parts.json').writeAsString(
      jsonEncode([
        {
          'entry_part': {
            'id': 1,
            'entry_id': 22,
            'part_type': 0,
            'entry_data': 'qPCR plate',
            'relative_position': 1.0,
          },
        },
        {
          'entry_part': {
            'id': 2,
            'entry_id': 22,
            'part_type': 1,
            'entry_data': '<p>Cycle threshold &amp; melt curve passed.</p>',
            'relative_position': 2.0,
          },
        },
        {
          'entry_part': {
            'id': 3,
            'entry_id': 22,
            'part_type': 2,
            'attach_file_name': 'raw_image.tif',
            'attach_file_size': 4,
            'entry_data': 'Raw microscopy image',
            'relative_position': 3.0,
          },
        },
      ]),
    );
    await Directory(
      '${dir.path}/notebook/attachments/3/1/original',
    ).create(recursive: true);
    await File(
      '${dir.path}/notebook/attachments/3/1/original/raw_image.tif',
    ).writeAsBytes([1, 2, 3, 4]);
    final archive = File('${dir.path}/notebook.7z');
    await archive.writeAsBytes([9, 8, 7]);

    final notebook = await BackupParser().parseExtractedBackup(
      extractedDir: dir,
      archivePath: 'backups/example/notebook.7z',
    );
    final verification = await BackupParser().verifyOriginalContents(
      extractedDir: dir,
      archive: archive,
      manifestFile: File('${dir.path}/original_files_manifest.json'),
      manifestPath: 'backups/example/original_files_manifest.json',
    );

    expect(notebook.name, 'Parser Test Notebook');
    expect(notebook.rootNodes.single.title, 'Assays');
    final page = notebook.childrenOf(10).single;
    expect(page.title, 'qPCR plate');
    expect(page.isPage, isTrue);
    expect(page.parts[1].renderText, 'Cycle threshold & melt curve passed.');
    expect(verification.isComplete, isTrue);
    expect(verification.expectedOriginalAttachmentCount, 1);
    expect(verification.verifiedOriginalAttachmentBytes, 4);
    expect(
      await File('${dir.path}/original_files_manifest.json').exists(),
      isTrue,
    );
  });
}
