import 'dart:convert';
import 'dart:io';

import 'backup_models.dart';

class BackupParser {
  Future<RenderNotebook> parseExtractedBackup({
    required Directory extractedDir,
    required String archivePath,
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

    final entryByTreeId = <int, Map<String, Object?>>{};
    for (final entry in entries) {
      final treeId = _intValue(entry['tree_id']);
      if (treeId != null) {
        entryByTreeId[treeId] = entry;
      }
    }

    final partsByEntryId = <int, List<RenderPart>>{};
    for (final rawPart in entryParts) {
      final entryId = _intValue(rawPart['entry_id']);
      if (entryId == null) {
        continue;
      }
      partsByEntryId.putIfAbsent(entryId, () => []).add(_renderPart(rawPart));
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

  RenderPart _renderPart(Map<String, Object?> rawPart) {
    final code = _intValue(rawPart['part_type']) ?? -1;
    final attachmentName = _stringValue(rawPart['attach_file_name']);
    return RenderPart(
      id: _intValue(rawPart['id']) ?? 0,
      kindCode: code,
      kindLabel: attachmentName == null ? _partTypeLabel(code) : 'Attachment',
      renderText: _renderText(_stringValue(rawPart['entry_data']) ?? ''),
      position: _doubleValue(rawPart['relative_position']) ?? 0,
      attachmentName: attachmentName,
      attachmentContentType: _stringValue(rawPart['attach_content_type']),
      attachmentSize: _intValue(rawPart['attach_file_size']),
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

String _join(String first, [String? second, String? third, String? fourth]) {
  final parts = <String>[first];
  for (final part in [second, third, fourth]) {
    if (part != null && part.isNotEmpty) {
      parts.add(part);
    }
  }
  return parts.join(Platform.pathSeparator);
}

class _NotebookInfo {
  const _NotebookInfo(this.name);

  final String name;
}
