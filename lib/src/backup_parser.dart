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
      nodes: nodes,
    );
  }

  Future<BackupContentVerification> verifyOriginalContents({
    required Directory extractedDir,
    required File archive,
    required File manifestFile,
    required String manifestPath,
  }) async {
    final entryParts = await _readWrappedList(
      File(_join(extractedDir.path, 'notebook', 'entry_parts.json')),
      'entry_part',
    );

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
      final expectedSize = _intValue(rawPart['attach_file_size']) ?? 0;
      expectedBytes += expectedSize;
      final original = await _findOriginalAttachment(
        extractedDir: extractedDir,
        partId: partId,
        fileName: fileName,
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

  Future<File?> _findOriginalAttachment({
    required Directory extractedDir,
    required int? partId,
    required String fileName,
  }) async {
    final attachmentsDir = Directory(
      _join(extractedDir.path, 'notebook', 'attachments'),
    );
    if (!await attachmentsDir.exists()) {
      return null;
    }
    if (partId != null) {
      final direct = File(
        _join(
          attachmentsDir.path,
          partId.toString(),
          '1',
          'original',
          fileName,
        ),
      );
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
      if (normalized.contains('original') &&
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
    List<RenderComment> comments = const [],
  }) async {
    final code = _intValue(rawPart['part_type']) ?? -1;
    final attachmentName = _stringValue(rawPart['attach_file_name']);
    String? originalPath;
    if (attachmentName != null && attachmentName.trim().isNotEmpty) {
      final original = await _findOriginalAttachment(
        extractedDir: extractedDir,
        partId: _intValue(rawPart['id']),
        fileName: attachmentName,
      );
      if (original != null) {
        originalPath = _relativeTo(
          backupRootPath ?? extractedDir.path,
          original.path,
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
    );
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
    return relative.startsWith(Platform.pathSeparator)
        ? relative.substring(1)
        : relative;
  }
  return path;
}

class _NotebookInfo {
  const _NotebookInfo(this.name);

  final String name;
}
