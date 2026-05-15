import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'backup_models.dart';

class BackupParser {
  Future<RenderNotebook> parseExtractedBackup({
    required Directory extractedDir,
    required String archivePath,
    String? backupRootPath,
  }) async {
    final notebookInfo = await _readNotebookInfo(extractedDir);
    final treeNodes = await _readWrappedList(
      File(_join(extractedDir.path, 'notebook', 'tree_nodes.json')),
      'tree_node',
    );
    if (treeNodes.isEmpty &&
        await File(
          _join(extractedDir.path, 'notebook', 'db.sqlite3'),
        ).exists()) {
      return _parseSqliteBackup(
        extractedDir: extractedDir,
        archivePath: archivePath,
        backupRootPath: backupRootPath,
        notebookName: notebookInfo.name,
      );
    }
    final entries = await _readWrappedList(
      File(_join(extractedDir.path, 'notebook', 'entries.json')),
      'entry',
    );
    final entryParts = await _readWrappedList(
      File(_join(extractedDir.path, 'notebook', 'entry_parts.json')),
      'entry_part',
    );
    final comments = await _readWrappedList(
      File(_join(extractedDir.path, 'notebook', 'comments.json')),
      'comment',
    );
    final entryPartVersions = await _readWrappedList(
      File(_join(extractedDir.path, 'notebook', 'entry_part_versions.json')),
      'entry_part_version',
    );
    final originalVersionByPartId = _originalVersionByPartId(entryPartVersions);

    final entryByTreeId = <int, Map<String, Object?>>{};
    for (final entry in entries) {
      final treeId = _intValue(entry['tree_id']);
      if (treeId != null) {
        entryByTreeId[treeId] = entry;
      }
    }

    final commentsByPartId = <int, List<RenderComment>>{};
    for (final rawComment in comments) {
      final partId = _intValue(rawComment['entry_part_id']);
      if (partId == null) {
        continue;
      }
      commentsByPartId
          .putIfAbsent(partId, () => [])
          .add(_renderComment(rawComment));
    }
    for (final partComments in commentsByPartId.values) {
      partComments.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }

    final partsByEntryId = <int, List<RenderPart>>{};
    for (final rawPart in entryParts) {
      final entryId = _intValue(rawPart['entry_id']);
      if (entryId == null) {
        continue;
      }
      partsByEntryId
          .putIfAbsent(entryId, () => [])
          .add(
            await _renderPart(
              rawPart,
              extractedDir: extractedDir,
              backupRootPath: backupRootPath,
              originalVersion:
                  originalVersionByPartId[_intValue(rawPart['id'])],
              comments: commentsByPartId[_intValue(rawPart['id'])] ?? const [],
            ),
          );
    }
    for (final parts in partsByEntryId.values) {
      parts.sort((a, b) => a.position.compareTo(b.position));
    }

    final nodes = <RenderNode>[];
    for (final rawNode in treeNodes) {
      final id = _intValue(rawNode['id']);
      if (id == null) {
        continue;
      }
      final entryId =
          _intValue(rawNode['entry_id']) ?? _intValue(entryByTreeId[id]?['id']);
      final parts = entryId == null
          ? <RenderPart>[]
          : (partsByEntryId[entryId] ?? <RenderPart>[]);
      final isPage = parts.isNotEmpty;
      nodes.add(
        RenderNode(
          id: id,
          parentId: _intValue(rawNode['parent_id']) ?? 0,
          title: _nodeTitle(rawNode, parts, id),
          isPage: isPage,
          position: _doubleValue(rawNode['relative_position']) ?? 0,
          parts: parts,
        ),
      );
    }

    nodes.sort((a, b) {
      final parent = a.parentId.compareTo(b.parentId);
      if (parent != 0) {
        return parent;
      }
      return a.position.compareTo(b.position);
    });

    return RenderNotebook(
      name: notebookInfo.name,
      createdAt: DateTime.now().toUtc(),
      archivePath: archivePath,
      sourceLayout: 'json',
      nodes: nodes,
    );
  }

  Future<BackupContentVerification> verifyOriginalContents({
    required Directory extractedDir,
    required File archive,
    required File manifestFile,
    required String manifestPath,
  }) async {
    var entryParts = await _readWrappedList(
      File(_join(extractedDir.path, 'notebook', 'entry_parts.json')),
      'entry_part',
    );
    var entryPartVersions = await _readWrappedList(
      File(_join(extractedDir.path, 'notebook', 'entry_part_versions.json')),
      'entry_part_version',
    );
    final sqliteDb = File(_join(extractedDir.path, 'notebook', 'db.sqlite3'));
    if (entryParts.isEmpty && await sqliteDb.exists()) {
      final tables = await _sqliteRows(
        sqliteDb,
        "SELECT name FROM sqlite_schema WHERE type='table'",
      );
      final tableNames = tables
          .map((row) => _stringValue(row['name']))
          .whereType<String>()
          .toSet();
      if (tableNames.contains('entry_parts')) {
        final partCols = await _sqliteColumns(sqliteDb, 'entry_parts');
        entryParts = await _sqliteRows(
          sqliteDb,
          'SELECT '
          '${_sqliteColumn(partCols, 'id')}, '
          '${_sqliteColumn(partCols, 'entry_id')}, '
          '${_sqliteColumn(partCols, 'part_type')}, '
          '${_sqliteColumn(partCols, 'entry_data')}, '
          '${_sqliteColumn(partCols, 'attach_file_name')}, '
          '${_sqliteColumn(partCols, 'attach_content_type')}, '
          '${_sqliteColumn(partCols, 'attach_file_size')}, '
          '${_sqliteColumn(partCols, 'version')}, '
          '${_sqliteColumn(partCols, 'relative_position', fallback: 'id')} '
          'FROM entry_parts',
        );
      }
      if (tableNames.contains('entry_part_versions')) {
        final versionCols = await _sqliteColumns(
          sqliteDb,
          'entry_part_versions',
        );
        entryPartVersions = await _sqliteRows(
          sqliteDb,
          'SELECT '
          '${_sqliteColumn(versionCols, 'entry_part_id')}, '
          '${_sqliteColumn(versionCols, 'version')}, '
          '${_sqliteColumn(versionCols, 'last_modified_verb')} '
          'FROM entry_part_versions',
        );
      }
    }
    final originalVersionByPartId = _originalVersionByPartId(entryPartVersions);

    var expectedCount = 0;
    var verifiedCount = 0;
    var expectedBytes = 0;
    var verifiedBytes = 0;
    final missing = <String>[];
    final mismatches = <String>[];
    final files = <Map<String, Object?>>[];

    for (final rawPart in entryParts) {
      final fileName = _stringValue(rawPart['attach_file_name']);
      if (fileName == null || fileName.trim().isEmpty) {
        continue;
      }
      expectedCount += 1;
      final partId = _intValue(rawPart['id']);
      final originalVersion = originalVersionByPartId[partId];
      final expectedSize = _intValue(rawPart['attach_file_size']) ?? 0;
      expectedBytes += expectedSize;
      final original = await _findAttachmentRendition(
        extractedDir: extractedDir,
        partId: partId,
        fileName: fileName,
        rendition: 'original',
        preferredVersion: originalVersion,
      );
      if (original == null) {
        missing.add('${partId ?? 'unknown'}:$fileName');
        continue;
      }
      final actualSize = await original.length();
      final relativePath = _relativeTo(extractedDir.path, original.path);
      final digest = await sha256.bind(original.openRead()).first;
      files.add({
        'entryPartId': partId,
        'fileName': fileName,
        'version': _intValue(rawPart['version']),
        'originalVersion': originalVersion,
        'relativePath': relativePath,
        'expectedBytes': expectedSize,
        'actualBytes': actualSize,
        'sha256': digest.toString(),
      });
      if (actualSize != expectedSize) {
        mismatches.add(
          '${partId ?? 'unknown'}:$fileName expected $expectedSize bytes, got $actualSize bytes',
        );
        continue;
      }
      verifiedCount += 1;
      verifiedBytes += actualSize;
    }

    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'manifestVersion': 1,
        'policy': 'full_original_attachment_payloads',
        'sourceArchive': archive.uri.pathSegments.isEmpty
            ? archive.path
            : archive.uri.pathSegments.last,
        'archiveBytes': await archive.length(),
        'expectedOriginalAttachmentCount': expectedCount,
        'verifiedOriginalAttachmentCount': verifiedCount,
        'expectedOriginalAttachmentBytes': expectedBytes,
        'verifiedOriginalAttachmentBytes': verifiedBytes,
        'files': files,
        'missingOriginals': missing,
        'sizeMismatches': mismatches,
      }),
    );

    return BackupContentVerification(
      archiveBytes: await archive.length(),
      expectedOriginalAttachmentCount: expectedCount,
      verifiedOriginalAttachmentCount: verifiedCount,
      expectedOriginalAttachmentBytes: expectedBytes,
      verifiedOriginalAttachmentBytes: verifiedBytes,
      manifestPath: manifestPath,
      missingOriginals: missing,
      sizeMismatches: mismatches,
    );
  }

  Future<File?> _findAttachmentRendition({
    required Directory extractedDir,
    required int? partId,
    required String fileName,
    required String rendition,
    int? preferredVersion,
  }) async {
    final attachmentsDir = Directory(
      _join(extractedDir.path, 'notebook', 'attachments'),
    );
    if (!await attachmentsDir.exists()) {
      return null;
    }
    File directFor(int version) => File(
      _join(
        attachmentsDir.path,
        partId.toString(),
        version.toString(),
        rendition,
        fileName,
      ),
    );
    if (partId != null && preferredVersion != null) {
      final direct = directFor(preferredVersion);
      if (await direct.exists()) {
        return direct;
      }
    }
    if (partId != null) {
      final direct = directFor(1);
      if (await direct.exists()) {
        return direct;
      }
    }

    final partRoot = partId == null
        ? attachmentsDir
        : Directory(_join(attachmentsDir.path, partId.toString()));
    if (!await partRoot.exists()) {
      return null;
    }
    await for (final entity in partRoot.list(recursive: true)) {
      if (entity is! File) {
        continue;
      }
      final normalized = entity.path.split(Platform.pathSeparator);
      if (normalized.contains(rendition) &&
          normalized.isNotEmpty &&
          normalized.last == fileName) {
        return entity;
      }
    }
    return null;
  }

  Future<_NotebookInfo> _readNotebookInfo(Directory extractedDir) async {
    final file = File(_join(extractedDir.path, 'notebook.json'));
    if (!await file.exists()) {
      return const _NotebookInfo('Untitled notebook');
    }
    final json = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final notebook = json['notebook'];
    if (notebook is Map<String, Object?>) {
      final name = notebook['name'];
      if (name is String && name.trim().isNotEmpty) {
        return _NotebookInfo(name.trim());
      }
    }
    return const _NotebookInfo('Untitled notebook');
  }

  Future<List<Map<String, Object?>>> _readWrappedList(
    File file,
    String wrapperKey,
  ) async {
    if (!await file.exists()) {
      return const [];
    }
    final raw = jsonDecode(await file.readAsString());
    if (raw is! List<Object?>) {
      return const [];
    }
    final rows = <Map<String, Object?>>[];
    for (final item in raw) {
      if (item is Map<String, Object?>) {
        final wrapped = item[wrapperKey];
        if (wrapped is Map<String, Object?>) {
          rows.add(wrapped);
        } else {
          rows.add(item);
        }
      }
    }
    return rows;
  }

  Future<RenderPart> _renderPart(
    Map<String, Object?> rawPart, {
    required Directory extractedDir,
    String? backupRootPath,
    int? originalVersion,
    List<RenderComment> comments = const [],
  }) async {
    final code = _intValue(rawPart['part_type']) ?? -1;
    final attachmentName = _stringValue(rawPart['attach_file_name']);
    String? originalPath;
    String? thumbnailPath;
    if (attachmentName != null && attachmentName.trim().isNotEmpty) {
      final partId = _intValue(rawPart['id']);
      final original = await _findAttachmentRendition(
        extractedDir: extractedDir,
        partId: partId,
        fileName: attachmentName,
        rendition: 'original',
        preferredVersion: originalVersion,
      );
      if (original != null) {
        originalPath = _relativeTo(
          backupRootPath ?? extractedDir.path,
          original.path,
        );
      }
      final thumbnail = await _findAttachmentRendition(
        extractedDir: extractedDir,
        partId: partId,
        fileName: attachmentName,
        rendition: 'thumb',
        preferredVersion: originalVersion,
      );
      if (thumbnail != null) {
        thumbnailPath = _relativeTo(
          backupRootPath ?? extractedDir.path,
          thumbnail.path,
        );
      }
    }
    return RenderPart(
      id: _intValue(rawPart['id']) ?? 0,
      kindCode: code,
      kindLabel: attachmentName == null ? _partTypeLabel(code) : 'Attachment',
      renderText: _renderText(_stringValue(rawPart['entry_data']) ?? ''),
      position: _doubleValue(rawPart['relative_position']) ?? 0,
      comments: comments,
      attachmentName: attachmentName,
      attachmentContentType: _stringValue(rawPart['attach_content_type']),
      attachmentSize: _intValue(rawPart['attach_file_size']),
      attachmentOriginalPath: originalPath,
      attachmentThumbnailPath: thumbnailPath,
      attachmentVersion: _intValue(rawPart['version']),
      attachmentOriginalVersion: originalVersion,
    );
  }

  Future<RenderNotebook> _parseSqliteBackup({
    required Directory extractedDir,
    required String archivePath,
    required String? backupRootPath,
    required String notebookName,
  }) async {
    final db = File(_join(extractedDir.path, 'notebook', 'db.sqlite3'));
    final tables = await _sqliteRows(
      db,
      "SELECT name FROM sqlite_schema WHERE type='table'",
    );
    final tableNames = tables
        .map((row) => _stringValue(row['name']))
        .whereType<String>()
        .toSet();
    if (!tableNames.contains('tree_nodes') ||
        !tableNames.contains('entry_parts')) {
      throw StateError(
        'SQLite LabArchives backup is missing tree_nodes or entry_parts tables.',
      );
    }

    final treeCols = await _sqliteColumns(db, 'tree_nodes');
    final partCols = await _sqliteColumns(db, 'entry_parts');
    final versionCols = tableNames.contains('entry_part_versions')
        ? await _sqliteColumns(db, 'entry_part_versions')
        : <String>{};

    final treeNodes = await _sqliteRows(
      db,
      'SELECT '
      '${_sqliteColumn(treeCols, 'id')}, '
      '${_sqliteColumn(treeCols, 'display_text')}, '
      '${_sqliteColumn(treeCols, 'parent_id')}, '
      '${_sqliteColumn(treeCols, 'entry_id')}, '
      '${_sqliteColumn(treeCols, 'relative_position', fallback: 'id')} '
      'FROM tree_nodes',
    );
    final entryParts = await _sqliteRows(
      db,
      'SELECT '
      '${_sqliteColumn(partCols, 'id')}, '
      '${_sqliteColumn(partCols, 'entry_id')}, '
      '${_sqliteColumn(partCols, 'part_type')}, '
      '${_sqliteColumn(partCols, 'entry_data')}, '
      '${_sqliteColumn(partCols, 'attach_file_name')}, '
      '${_sqliteColumn(partCols, 'attach_content_type')}, '
      '${_sqliteColumn(partCols, 'attach_file_size')}, '
      '${_sqliteColumn(partCols, 'version')}, '
      '${_sqliteColumn(partCols, 'relative_position', fallback: 'id')} '
      'FROM entry_parts',
    );
    final entryPartVersions = tableNames.contains('entry_part_versions')
        ? await _sqliteRows(
            db,
            'SELECT '
            '${_sqliteColumn(versionCols, 'entry_part_id')}, '
            '${_sqliteColumn(versionCols, 'version')}, '
            '${_sqliteColumn(versionCols, 'last_modified_verb')} '
            'FROM entry_part_versions',
          )
        : <Map<String, Object?>>[];
    final originalVersionByPartId = _originalVersionByPartId(entryPartVersions);

    final partsByEntryId = <int, List<RenderPart>>{};
    for (final rawPart in entryParts) {
      final entryId = _intValue(rawPart['entry_id']);
      if (entryId == null) {
        continue;
      }
      partsByEntryId
          .putIfAbsent(entryId, () => [])
          .add(
            await _renderPart(
              rawPart,
              extractedDir: extractedDir,
              backupRootPath: backupRootPath,
              originalVersion:
                  originalVersionByPartId[_intValue(rawPart['id'])],
            ),
          );
    }
    for (final parts in partsByEntryId.values) {
      parts.sort((a, b) => a.position.compareTo(b.position));
    }

    final nodes = <RenderNode>[];
    for (final rawNode in treeNodes) {
      final id = _intValue(rawNode['id']);
      if (id == null) {
        continue;
      }
      final entryId = _intValue(rawNode['entry_id']);
      final parts = entryId == null
          ? <RenderPart>[]
          : (partsByEntryId[entryId] ?? <RenderPart>[]);
      nodes.add(
        RenderNode(
          id: id,
          parentId: _intValue(rawNode['parent_id']) ?? 0,
          title: _nodeTitle(rawNode, parts, id),
          isPage: parts.isNotEmpty,
          position: _doubleValue(rawNode['relative_position']) ?? id.toDouble(),
          parts: parts,
        ),
      );
    }
    nodes.sort((a, b) {
      final parent = a.parentId.compareTo(b.parentId);
      if (parent != 0) {
        return parent;
      }
      return a.position.compareTo(b.position);
    });

    return RenderNotebook(
      name: notebookName,
      createdAt: DateTime.now().toUtc(),
      archivePath: archivePath,
      sourceLayout: 'sqlite',
      nodes: nodes,
    );
  }

  Future<Set<String>> _sqliteColumns(File db, String table) async {
    final rows = await _sqliteRows(db, "PRAGMA table_info('$table')");
    return rows
        .map((row) => _stringValue(row['name']))
        .whereType<String>()
        .toSet();
  }

  Future<List<Map<String, Object?>>> _sqliteRows(File db, String sql) async {
    final ProcessResult result;
    try {
      result = await Process.run('sqlite3', ['-json', db.path, sql]);
    } on ProcessException catch (error) {
      throw StateError(
        'SQLite backup parsing requires the sqlite3 command: ${error.message}',
      );
    }
    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      throw StateError(
        stderr.isEmpty
            ? 'SQLite backup parsing requires the sqlite3 command.'
            : 'SQLite backup parsing failed: $stderr',
      );
    }
    final raw = result.stdout.toString().trim();
    if (raw.isEmpty) {
      return const [];
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) {
      return const [];
    }
    return decoded.whereType<Map<String, Object?>>().toList();
  }

  String _sqliteColumn(Set<String> columns, String name, {String? fallback}) {
    if (columns.contains(name)) {
      return name;
    }
    if (fallback != null && columns.contains(fallback)) {
      return '$fallback AS $name';
    }
    return 'NULL AS $name';
  }

  Map<int, int> _originalVersionByPartId(
    List<Map<String, Object?>> versionRows,
  ) {
    const uploadVerbs = {2, 6, 7, 13, 14, 16};
    final byPart = <int, int>{};
    for (final row in versionRows) {
      final partId = _intValue(row['entry_part_id']);
      final version = _intValue(row['version']);
      if (partId == null || version == null) {
        continue;
      }
      final verb = _intValue(row['last_modified_verb']);
      if (verb != null && !uploadVerbs.contains(verb)) {
        continue;
      }
      final current = byPart[partId];
      if (current == null || version > current) {
        byPart[partId] = version;
      }
    }
    return byPart;
  }

  RenderComment _renderComment(Map<String, Object?> rawComment) {
    final author =
        _stringValue(rawComment['user_name']) ??
        _stringValue(rawComment['user_email']);
    return RenderComment(
      id: _intValue(rawComment['id']) ?? 0,
      text: _renderText(_stringValue(rawComment['the_comment']) ?? ''),
      createdAt: _stringValue(rawComment['created_at']) ?? '',
      author: author,
    );
  }

  String _nodeTitle(
    Map<String, Object?> rawNode,
    List<RenderPart> parts,
    int id,
  ) {
    final displayText = _stringValue(rawNode['display_text']);
    if (displayText != null && displayText.trim().isNotEmpty) {
      return displayText.trim();
    }
    for (final part in parts) {
      if (part.kindCode == 0 && part.renderText.trim().isNotEmpty) {
        return part.renderText.trim().split('\n').first;
      }
    }
    return 'Page $id';
  }

  String _partTypeLabel(int code) {
    return switch (code) {
      0 => 'Heading',
      1 => 'Rich text',
      5 => 'Plain text',
      _ => 'Entry part $code',
    };
  }

  String _renderText(String raw) {
    if (raw.isEmpty) {
      return '';
    }
    var text = raw
        .replaceAll(RegExp(r'<!--RTE_[\s\S]*?-->'), '')
        .replaceAllMapped(
          RegExp(
            r'''<a\s+[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)</a>''',
            caseSensitive: false,
          ),
          (match) {
            final label = (match.group(2) ?? '').replaceAll(
              RegExp(r'<[^>]+>'),
              '',
            );
            final href = match.group(1) ?? '';
            return href.isEmpty ? label : '$label ($href)';
          },
        )
        .replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n')
        .replaceAll(
          RegExp(r'</\s*(p|div|li|tr|h[1-6])\s*>', caseSensitive: false),
          '\n',
        )
        .replaceAll(RegExp(r'</\s*(td|th)\s*>', caseSensitive: false), '\t')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    return text
        .split('\n')
        .map((line) => line.trimRight())
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  String? _stringValue(Object? value) {
    if (value == null) {
      return null;
    }
    final string = value.toString();
    return string == 'null' ? null : string;
  }

  int? _intValue(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      return int.tryParse(value);
    }
    return null;
  }

  double? _doubleValue(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }
}

String _join(
  String first, [
  String? second,
  String? third,
  String? fourth,
  String? fifth,
]) {
  final parts = <String>[first];
  for (final part in [second, third, fourth, fifth]) {
    if (part != null && part.isNotEmpty) {
      parts.add(part);
    }
  }
  return parts.join(Platform.pathSeparator);
}

String _relativeTo(String base, String path) {
  final normalizedBase = Directory(base).absolute.path;
  final normalizedPath = File(path).absolute.path;
  if (normalizedPath.startsWith(normalizedBase)) {
    final relative = normalizedPath.substring(normalizedBase.length);
    final trimmed = relative.startsWith(Platform.pathSeparator)
        ? relative.substring(1)
        : relative;
    return _portableRelativePath(trimmed);
  }
  return path;
}

String _portableRelativePath(String path) {
  return path
      .split(RegExp(r'[\\/]+'))
      .where((segment) => segment.isNotEmpty)
      .join('/');
}

class _NotebookInfo {
  const _NotebookInfo(this.name);

  final String name;
}
