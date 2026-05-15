import 'dart:convert';
import 'dart:io';

import 'package:benchvault/src/backup_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses LabArchives JSON backup tables into render nodes', () async {
    final dir = await Directory.systemTemp.createTemp(
      'benchvault_parser_test_',
    );
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
    await File('${dir.path}/notebook/entry_part_versions.json').writeAsString(
      jsonEncode([
        {
          'entry_part_version': {
            'entry_part_id': 3,
            'version': 1,
            'last_modified_verb': 2,
          },
        },
        {
          'entry_part_version': {
            'entry_part_id': 3,
            'version': 2,
            'last_modified_verb': 6,
          },
        },
      ]),
    );
    await File('${dir.path}/notebook/comments.json').writeAsString(
      jsonEncode([
        {
          'comment': {
            'id': 77,
            'entry_part_id': 2,
            'the_comment': '<p>Reviewer comment &amp; follow-up.</p>',
            'created_at': '2026-05-14T12:00:00Z',
            'user_name': 'QA reviewer',
          },
        },
      ]),
    );
    await Directory(
      '${dir.path}/notebook/attachments/3/2/original',
    ).create(recursive: true);
    await File(
      '${dir.path}/notebook/attachments/3/2/original/raw_image.tif',
    ).writeAsBytes([1, 2, 3, 4]);
    await Directory(
      '${dir.path}/notebook/attachments/3/2/thumb',
    ).create(recursive: true);
    await File(
      '${dir.path}/notebook/attachments/3/2/thumb/raw_image.tif',
    ).writeAsBytes([255, 216, 255, 217]);
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
    expect(page.parts[1].comments.single.text, 'Reviewer comment & follow-up.');
    expect(page.parts[1].comments.single.author, 'QA reviewer');
    expect(
      page.parts[2].attachmentOriginalPath,
      'notebook/attachments/3/2/original/raw_image.tif',
    );
    expect(
      page.parts[2].attachmentThumbnailPath,
      'notebook/attachments/3/2/thumb/raw_image.tif',
    );
    expect(page.parts[2].attachmentOriginalVersion, 2);
    expect(verification.isComplete, isTrue);
    expect(verification.expectedOriginalAttachmentCount, 1);
    expect(verification.verifiedOriginalAttachmentBytes, 4);
    expect(
      await File('${dir.path}/original_files_manifest.json').exists(),
      isTrue,
    );
  });

  test('parses SQLite backup layout when JSON tables are absent', () async {
    final sqliteAvailable = await Process.run('which', ['sqlite3']);
    if (sqliteAvailable.exitCode != 0) {
      return;
    }
    final dir = await Directory.systemTemp.createTemp(
      'benchvault_sqlite_parser_test_',
    );
    addTearDown(() => dir.delete(recursive: true));
    await Directory('${dir.path}/notebook').create(recursive: true);
    await File('${dir.path}/notebook.json').writeAsString(
      jsonEncode({
        'notebook': {'name': 'SQLite Test Notebook'},
      }),
    );
    final dbPath = '${dir.path}/notebook/db.sqlite3';
    final sql = '''
CREATE TABLE tree_nodes (
  id INTEGER,
  display_text TEXT,
  parent_id INTEGER,
  entry_id INTEGER,
  relative_position REAL
);
CREATE TABLE entry_parts (
  id INTEGER,
  entry_id INTEGER,
  part_type INTEGER,
  entry_data TEXT,
  attach_file_name TEXT,
  attach_content_type TEXT,
  attach_file_size INTEGER,
  version INTEGER,
  relative_position REAL
);
CREATE TABLE entry_part_versions (
  entry_part_id INTEGER,
  version INTEGER,
  last_modified_verb INTEGER
);
INSERT INTO tree_nodes VALUES (1, 'Root', 0, -1, 1.0);
INSERT INTO tree_nodes VALUES (2, NULL, 1, 100, 1.0);
INSERT INTO entry_parts VALUES (10, 100, 0, 'SQLite page', NULL, NULL, NULL, 1, 1.0);
INSERT INTO entry_parts VALUES (11, 100, 2, 'Sequence export', 'amplicon.fasta', 'text/plain', 8, 2, 2.0);
INSERT INTO entry_part_versions VALUES (11, 2, 6);
''';
    final create = await Process.run('sqlite3', [dbPath, sql]);
    expect(create.exitCode, 0, reason: create.stderr.toString());
    await Directory(
      '${dir.path}/notebook/attachments/11/2/original',
    ).create(recursive: true);
    await File(
      '${dir.path}/notebook/attachments/11/2/original/amplicon.fasta',
    ).writeAsString('ATGCATGC');

    final notebook = await BackupParser().parseExtractedBackup(
      extractedDir: dir,
      archivePath: 'backups/sqlite/notebook.7z',
    );

    expect(notebook.sourceLayout, 'sqlite');
    expect(notebook.name, 'SQLite Test Notebook');
    final page = notebook.childrenOf(1).single;
    expect(page.title, 'SQLite page');
    expect(page.parts.last.attachmentOriginalVersion, 2);
    expect(
      page.parts.last.attachmentOriginalPath,
      'notebook/attachments/11/2/original/amplicon.fasta',
    );
  });
}
