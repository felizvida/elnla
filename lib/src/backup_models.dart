import 'dart:convert';

class NotebookSummary {
  const NotebookSummary({
    required this.name,
    required this.nbid,
    required this.isDefault,
  });

  final String name;
  final String nbid;
  final bool isDefault;
}

class BackupRecord {
  const BackupRecord({
    required this.id,
    required this.notebookName,
    required this.createdAt,
    required this.archivePath,
    required this.renderPath,
    required this.pageCount,
    this.contentVerification,
  });

  final String id;
  final String notebookName;
  final DateTime createdAt;
  final String archivePath;
  final String renderPath;
  final int pageCount;
  final BackupContentVerification? contentVerification;

  String get createdAtLabel {
    final local = createdAt.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'notebookName': notebookName,
    'createdAt': createdAt.toIso8601String(),
    'archivePath': archivePath,
    'renderPath': renderPath,
    'pageCount': pageCount,
    'contentVerification': contentVerification?.toJson(),
  };

  static BackupRecord fromJson(Map<String, Object?> json) {
    return BackupRecord(
      id: json['id'] as String,
      notebookName: json['notebookName'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      archivePath: json['archivePath'] as String,
      renderPath: json['renderPath'] as String,
      pageCount: json['pageCount'] as int,
      contentVerification: json['contentVerification'] is Map<String, Object?>
          ? BackupContentVerification.fromJson(
              json['contentVerification'] as Map<String, Object?>,
            )
          : null,
    );
  }
}

class BackupContentVerification {
  const BackupContentVerification({
    required this.archiveBytes,
    required this.expectedOriginalAttachmentCount,
    required this.verifiedOriginalAttachmentCount,
    required this.expectedOriginalAttachmentBytes,
    required this.verifiedOriginalAttachmentBytes,
    required this.manifestPath,
    required this.missingOriginals,
    required this.sizeMismatches,
  });

  final int archiveBytes;
  final int expectedOriginalAttachmentCount;
  final int verifiedOriginalAttachmentCount;
  final int expectedOriginalAttachmentBytes;
  final int verifiedOriginalAttachmentBytes;
  final String manifestPath;
  final List<String> missingOriginals;
  final List<String> sizeMismatches;

  bool get isComplete =>
      missingOriginals.isEmpty &&
      sizeMismatches.isEmpty &&
      verifiedOriginalAttachmentCount == expectedOriginalAttachmentCount &&
      verifiedOriginalAttachmentBytes == expectedOriginalAttachmentBytes;

  String get summary {
    if (expectedOriginalAttachmentCount == 0) {
      return 'no attachments';
    }
    return '$verifiedOriginalAttachmentCount/$expectedOriginalAttachmentCount originals, $verifiedOriginalAttachmentBytes bytes';
  }

  Map<String, Object?> toJson() => {
    'archiveBytes': archiveBytes,
    'expectedOriginalAttachmentCount': expectedOriginalAttachmentCount,
    'verifiedOriginalAttachmentCount': verifiedOriginalAttachmentCount,
    'expectedOriginalAttachmentBytes': expectedOriginalAttachmentBytes,
    'verifiedOriginalAttachmentBytes': verifiedOriginalAttachmentBytes,
    'manifestPath': manifestPath,
    'missingOriginals': missingOriginals,
    'sizeMismatches': sizeMismatches,
  };

  static BackupContentVerification fromJson(Map<String, Object?> json) {
    return BackupContentVerification(
      archiveBytes: json['archiveBytes'] as int? ?? 0,
      expectedOriginalAttachmentCount:
          json['expectedOriginalAttachmentCount'] as int? ?? 0,
      verifiedOriginalAttachmentCount:
          json['verifiedOriginalAttachmentCount'] as int? ?? 0,
      expectedOriginalAttachmentBytes:
          json['expectedOriginalAttachmentBytes'] as int? ?? 0,
      verifiedOriginalAttachmentBytes:
          json['verifiedOriginalAttachmentBytes'] as int? ?? 0,
      manifestPath: json['manifestPath'] as String? ?? '',
      missingOriginals: (json['missingOriginals'] as List<Object?>? ?? const [])
          .map((value) => value.toString())
          .toList(),
      sizeMismatches: (json['sizeMismatches'] as List<Object?>? ?? const [])
          .map((value) => value.toString())
          .toList(),
    );
  }
}

class RenderNotebook {
  const RenderNotebook({
    required this.name,
    required this.createdAt,
    required this.archivePath,
    required this.nodes,
  });

  final String name;
  final DateTime createdAt;
  final String archivePath;
  final List<RenderNode> nodes;

  List<RenderNode> get rootNodes {
    final roots = nodes.where((node) => node.parentId == 0).toList()
      ..sort((a, b) => a.position.compareTo(b.position));
    return roots;
  }

  RenderNode? get firstPage {
    for (final node in nodes) {
      if (node.isPage) {
        return node;
      }
    }
    return null;
  }

  List<RenderNode> childrenOf(int parentId) {
    return nodes.where((node) => node.parentId == parentId).toList()
      ..sort((a, b) => a.position.compareTo(b.position));
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    'archivePath': archivePath,
    'nodes': nodes.map((node) => node.toJson()).toList(),
  };

  static RenderNotebook fromJson(Map<String, Object?> json) {
    final rawNodes = json['nodes'] as List<Object?>? ?? const [];
    return RenderNotebook(
      name: json['name'] as String? ?? 'Untitled notebook',
      createdAt: DateTime.parse(json['createdAt'] as String),
      archivePath: json['archivePath'] as String? ?? '',
      nodes: rawNodes
          .cast<Map<String, Object?>>()
          .map(RenderNode.fromJson)
          .toList(),
    );
  }

  String toPrettyJson() => const JsonEncoder.withIndent('  ').convert(toJson());
}

class RenderNode {
  const RenderNode({
    required this.id,
    required this.parentId,
    required this.title,
    required this.isPage,
    required this.position,
    required this.parts,
  });

  final int id;
  final int parentId;
  final String title;
  final bool isPage;
  final double position;
  final List<RenderPart> parts;

  Map<String, Object?> toJson() => {
    'id': id,
    'parentId': parentId,
    'title': title,
    'isPage': isPage,
    'position': position,
    'parts': parts.map((part) => part.toJson()).toList(),
  };

  static RenderNode fromJson(Map<String, Object?> json) {
    final rawParts = json['parts'] as List<Object?>? ?? const [];
    return RenderNode(
      id: json['id'] as int,
      parentId: json['parentId'] as int? ?? 0,
      title: json['title'] as String? ?? 'Untitled',
      isPage: json['isPage'] as bool? ?? false,
      position: (json['position'] as num?)?.toDouble() ?? 0,
      parts: rawParts
          .cast<Map<String, Object?>>()
          .map(RenderPart.fromJson)
          .toList(),
    );
  }
}

class RenderPart {
  const RenderPart({
    required this.id,
    required this.kindCode,
    required this.kindLabel,
    required this.renderText,
    required this.position,
    this.attachmentName,
    this.attachmentContentType,
    this.attachmentSize,
    this.attachmentOriginalPath,
  });

  final int id;
  final int kindCode;
  final String kindLabel;
  final String renderText;
  final double position;
  final String? attachmentName;
  final String? attachmentContentType;
  final int? attachmentSize;
  final String? attachmentOriginalPath;

  bool get isAttachment => attachmentName != null && attachmentName!.isNotEmpty;

  String get attachmentSummary {
    final pieces = <String>[];
    if (attachmentContentType != null && attachmentContentType!.isNotEmpty) {
      pieces.add(attachmentContentType!);
    }
    if (attachmentSize != null) {
      pieces.add('${attachmentSize!} bytes');
    }
    return pieces.isEmpty
        ? 'Attachment preserved in backup archive'
        : pieces.join(' · ');
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'kindCode': kindCode,
    'kindLabel': kindLabel,
    'renderText': renderText,
    'position': position,
    'attachmentName': attachmentName,
    'attachmentContentType': attachmentContentType,
    'attachmentSize': attachmentSize,
    'attachmentOriginalPath': attachmentOriginalPath,
  };

  static RenderPart fromJson(Map<String, Object?> json) {
    return RenderPart(
      id: json['id'] as int,
      kindCode: json['kindCode'] as int? ?? -1,
      kindLabel: json['kindLabel'] as String? ?? 'Entry part',
      renderText: json['renderText'] as String? ?? '',
      position: (json['position'] as num?)?.toDouble() ?? 0,
      attachmentName: json['attachmentName'] as String?,
      attachmentContentType: json['attachmentContentType'] as String?,
      attachmentSize: json['attachmentSize'] as int?,
      attachmentOriginalPath: json['attachmentOriginalPath'] as String?,
    );
  }
}
