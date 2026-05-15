import 'dart:convert';
import 'dart:io';

import 'backup_models.dart';
import 'search_models.dart';

class ReadableNotebookArtifacts {
  const ReadableNotebookArtifacts({
    required this.markdownPath,
    required this.searchIndexPath,
    required this.chunkCount,
  });

  final String markdownPath;
  final String searchIndexPath;
  final int chunkCount;
}

class ReadableNotebookExporter {
  Future<ReadableNotebookArtifacts> write({
    required BackupRecord record,
    required RenderNotebook notebook,
    required Directory runDir,
    required String backupRootPath,
  }) async {
    final readableDir = Directory(_join(runDir.path, 'readable'));
    await readableDir.create(recursive: true);

    final markdownFile = File(_join(readableDir.path, 'notebook.md'));
    final searchIndexFile = File(
      _join(readableDir.path, 'search_chunks.jsonl'),
    );
    final markdownPath = _relativeTo(backupRootPath, markdownFile.path);
    final searchIndexPath = _relativeTo(backupRootPath, searchIndexFile.path);
    final chunks = buildChunks(record: record, notebook: notebook);

    await markdownFile.writeAsString(
      _toMarkdown(
        record: record,
        notebook: notebook,
        searchIndexPath: searchIndexPath,
      ),
    );
    await searchIndexFile.writeAsString(
      chunks.map((chunk) => jsonEncode(chunk.toJson())).join('\n') +
          (chunks.isEmpty ? '' : '\n'),
    );

    return ReadableNotebookArtifacts(
      markdownPath: markdownPath,
      searchIndexPath: searchIndexPath,
      chunkCount: chunks.length,
    );
  }

  List<NotebookSearchChunk> buildChunks({
    required BackupRecord record,
    required RenderNotebook notebook,
  }) {
    final nodesById = {for (final node in notebook.nodes) node.id: node};
    final chunks = <NotebookSearchChunk>[];
    for (final node in notebook.nodes.where((node) => node.isPage)) {
      final path = _nodePath(node, nodesById);
      final pageText = _pageSearchText(node, path);
      final attachments = node.parts
          .where((part) => part.isAttachment)
          .map((part) => _attachmentLine(part))
          .toList();
      final commentCount = node.parts.fold<int>(
        0,
        (count, part) => count + part.comments.length,
      );
      final split = _splitText(pageText, maxChars: 4500);
      for (var index = 0; index < split.length; index++) {
        chunks.add(
          NotebookSearchChunk(
            id: '${record.id}:${node.id}:${index + 1}',
            backupId: record.id,
            notebookName: record.notebookName,
            backupCreatedAt: record.createdAt,
            nodeId: node.id,
            pageTitle: node.title,
            path: path,
            text: split[index],
            attachments: attachments,
            commentCount: commentCount,
            partCount: node.parts.length,
          ),
        );
      }
    }
    return chunks;
  }

  String _toMarkdown({
    required BackupRecord record,
    required RenderNotebook notebook,
    required String searchIndexPath,
  }) {
    final nodesById = {for (final node in notebook.nodes) node.id: node};
    final buffer = StringBuffer()
      ..writeln('# ${_oneLine(record.notebookName)}')
      ..writeln()
      ..writeln('- Backup ID: `${record.id}`')
      ..writeln('- Backup created: `${record.createdAt.toIso8601String()}`')
      ..writeln('- Faithful archive: `${record.archivePath}`')
      ..writeln('- Viewer JSON: `${record.renderPath}`')
      ..writeln('- Parsed source layout: `${notebook.sourceLayout}`')
      ..writeln('- Search chunks: `$searchIndexPath`');
    final verification = record.contentVerification;
    if (verification != null) {
      buffer
        ..writeln('- Original attachment check: `${verification.summary}`')
        ..writeln('- Original manifest: `${verification.manifestPath}`');
    }
    buffer
      ..writeln()
      ..writeln('## Table of Contents');
    for (final node in notebook.nodes.where((node) => node.isPage)) {
      buffer.writeln('- ${_nodePath(node, nodesById)}');
    }
    buffer.writeln();

    for (final node in notebook.nodes.where((node) => node.isPage)) {
      buffer
        ..writeln('## ${_oneLine(node.title)}')
        ..writeln()
        ..writeln('Path: `${_nodePath(node, nodesById)}`')
        ..writeln();
      if (node.parts.isEmpty) {
        buffer
          ..writeln('_No entry parts in this backed-up page._')
          ..writeln();
        continue;
      }
      final parts = [...node.parts]
        ..sort((a, b) => a.position.compareTo(b.position));
      for (final part in parts) {
        buffer
          ..writeln('### Part ${part.id}: ${_oneLine(part.kindLabel)}')
          ..writeln();
        if (part.isAttachment) {
          buffer
            ..writeln('- Attachment: `${part.attachmentName ?? 'attachment'}`')
            ..writeln('- Metadata: ${part.attachmentSummary}');
          final originalPath = part.attachmentOriginalPath;
          if (originalPath != null && originalPath.isNotEmpty) {
            buffer.writeln('- Original payload: `$originalPath`');
          }
          final thumbnailPath = part.attachmentThumbnailPath;
          if (thumbnailPath != null && thumbnailPath.isNotEmpty) {
            buffer.writeln('- Thumbnail: `$thumbnailPath`');
          }
          if (part.attachmentOriginalVersion != null) {
            buffer.writeln(
              '- Original payload version: `${part.attachmentOriginalVersion}`',
            );
          } else if (part.attachmentVersion != null) {
            buffer.writeln('- Entry part version: `${part.attachmentVersion}`');
          }
          if (part.renderText.trim().isNotEmpty) {
            buffer
              ..writeln()
              ..writeln(part.renderText.trim());
          }
        } else {
          buffer.writeln(
            part.renderText.trim().isEmpty ? '_Empty part._' : part.renderText,
          );
        }
        if (part.comments.isNotEmpty) {
          buffer
            ..writeln()
            ..writeln('Comments:');
          for (final comment in part.comments) {
            final label = [
              if (comment.author != null && comment.author!.isNotEmpty)
                comment.author!,
              if (comment.createdAt.isNotEmpty) comment.createdAt,
            ].join(', ');
            buffer.writeln(
              '- ${label.isEmpty ? '' : '$label: '}${comment.text}',
            );
          }
        }
        buffer.writeln();
      }
    }
    return buffer.toString();
  }

  String _pageSearchText(RenderNode node, String path) {
    final buffer = StringBuffer()
      ..writeln('Notebook path: $path')
      ..writeln('Page title: ${node.title}');
    final parts = [...node.parts]
      ..sort((a, b) => a.position.compareTo(b.position));
    for (final part in parts) {
      buffer
        ..writeln()
        ..writeln('Part ${part.id}: ${part.kindLabel}');
      if (part.isAttachment) {
        buffer.writeln(_attachmentLine(part));
      }
      if (part.renderText.trim().isNotEmpty) {
        buffer.writeln(part.renderText.trim());
      }
      for (final comment in part.comments) {
        final author = comment.author == null || comment.author!.isEmpty
            ? 'comment'
            : 'comment by ${comment.author}';
        final when = comment.createdAt.isEmpty ? '' : ' ${comment.createdAt}';
        buffer.writeln('$author$when: ${comment.text}');
      }
    }
    return buffer.toString().trim();
  }

  String _attachmentLine(RenderPart part) {
    final pieces = <String>[
      'Attachment ${part.attachmentName ?? 'attachment'}',
      part.attachmentSummary,
    ];
    final originalPath = part.attachmentOriginalPath;
    if (originalPath != null && originalPath.isNotEmpty) {
      pieces.add('original payload $originalPath');
    }
    final thumbnailPath = part.attachmentThumbnailPath;
    if (thumbnailPath != null && thumbnailPath.isNotEmpty) {
      pieces.add('thumbnail $thumbnailPath');
    }
    if (part.attachmentOriginalVersion != null) {
      pieces.add('original version ${part.attachmentOriginalVersion}');
    } else if (part.attachmentVersion != null) {
      pieces.add('entry version ${part.attachmentVersion}');
    }
    return pieces.join('; ');
  }

  List<String> _splitText(String text, {required int maxChars}) {
    final clean = text.trim();
    if (clean.isEmpty) {
      return const [''];
    }
    if (clean.length <= maxChars) {
      return [clean];
    }
    final chunks = <String>[];
    final paragraphs = clean.split(RegExp(r'\n\s*\n'));
    var current = StringBuffer();
    for (final paragraph in paragraphs) {
      if (paragraph.length > maxChars) {
        if (current.length > 0) {
          chunks.add(current.toString().trim());
          current = StringBuffer();
        }
        for (var index = 0; index < paragraph.length; index += maxChars) {
          final end = index + maxChars > paragraph.length
              ? paragraph.length
              : index + maxChars;
          chunks.add(paragraph.substring(index, end).trim());
        }
        continue;
      }
      final nextLength = current.length + paragraph.length + 2;
      if (nextLength > maxChars && current.length > 0) {
        chunks.add(current.toString().trim());
        current = StringBuffer();
      }
      current
        ..writeln(paragraph)
        ..writeln();
    }
    if (current.length > 0) {
      chunks.add(current.toString().trim());
    }
    return chunks;
  }

  String _nodePath(RenderNode node, Map<int, RenderNode> nodesById) {
    final parts = <String>[];
    var current = node;
    final seen = <int>{};
    while (seen.add(current.id)) {
      parts.add(_oneLine(current.title));
      final parent = nodesById[current.parentId];
      if (parent == null) {
        break;
      }
      current = parent;
    }
    return parts.reversed.join(' / ');
  }

  String _oneLine(String value) {
    final clean = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return clean.isEmpty ? 'Untitled' : clean;
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
}

String _join(String first, [String? second, String? third]) {
  final parts = <String>[first];
  for (final part in [second, third]) {
    if (part != null && part.isNotEmpty) {
      parts.add(part);
    }
  }
  return parts.join(Platform.pathSeparator);
}
