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
    this.readablePath,
    this.searchIndexPath,
    this.integrityManifestPath,
    this.contentVerification,
  });

  final String id;
  final String notebookName;
  final DateTime createdAt;
  final String archivePath;
  final String renderPath;
  final int pageCount;
  final String? readablePath;
  final String? searchIndexPath;
  final String? integrityManifestPath;
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
    'readablePath': readablePath,
    'searchIndexPath': searchIndexPath,
    'integrityManifestPath': integrityManifestPath,
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
      readablePath: json['readablePath'] as String?,
      searchIndexPath: json['searchIndexPath'] as String?,
      integrityManifestPath: json['integrityManifestPath'] as String?,
      contentVerification: json['contentVerification'] is Map<String, Object?>
          ? BackupContentVerification.fromJson(
              json['contentVerification'] as Map<String, Object?>,
            )
          : null,
    );
  }

  BackupRecord copyWith({
    String? id,
    String? notebookName,
    DateTime? createdAt,
    String? archivePath,
    String? renderPath,
    int? pageCount,
    String? readablePath,
    String? searchIndexPath,
    String? integrityManifestPath,
    BackupContentVerification? contentVerification,
  }) {
    return BackupRecord(
      id: id ?? this.id,
      notebookName: notebookName ?? this.notebookName,
      createdAt: createdAt ?? this.createdAt,
      archivePath: archivePath ?? this.archivePath,
      renderPath: renderPath ?? this.renderPath,
      pageCount: pageCount ?? this.pageCount,
      readablePath: readablePath ?? this.readablePath,
      searchIndexPath: searchIndexPath ?? this.searchIndexPath,
      integrityManifestPath:
          integrityManifestPath ?? this.integrityManifestPath,
      contentVerification: contentVerification ?? this.contentVerification,
    );
  }
}

class BackupIntegrityCheck {
  const BackupIntegrityCheck({
    required this.backupId,
    required this.checkedAt,
    required this.hasManifest,
    required this.hasLocalSeal,
    required this.manifestPath,
    required this.checkedFileCount,
    required this.checkedBytes,
    this.manifestSha256,
    this.sealedManifestSha256,
    this.missingFiles = const [],
    this.changedFiles = const [],
    this.extraFiles = const [],
    this.error,
  });

  final String backupId;
  final DateTime checkedAt;
  final bool hasManifest;
  final bool hasLocalSeal;
  final String? manifestPath;
  final String? manifestSha256;
  final String? sealedManifestSha256;
  final int checkedFileCount;
  final int checkedBytes;
  final List<String> missingFiles;
  final List<String> changedFiles;
  final List<String> extraFiles;
  final String? error;

  bool get manifestMatchesSeal =>
      !hasLocalSeal ||
      (manifestSha256 != null && manifestSha256 == sealedManifestSha256);

  bool get filesMatch =>
      missingFiles.isEmpty && changedFiles.isEmpty && extraFiles.isEmpty;

  bool get isVerified =>
      hasManifest &&
      hasLocalSeal &&
      manifestMatchesSeal &&
      filesMatch &&
      error == null;

  bool get needsWarning => !isVerified;

  String get statusTitle {
    if (isVerified) {
      return 'Integrity verified';
    }
    if (!hasManifest) {
      return 'Backup is not integrity sealed';
    }
    if (!manifestMatchesSeal) {
      return 'Integrity seal does not match';
    }
    if (!filesMatch) {
      return 'Backup contents changed';
    }
    if (!hasLocalSeal) {
      return 'Local integrity seal missing';
    }
    return 'Integrity check warning';
  }

  String get summary {
    if (isVerified) {
      return '$checkedFileCount files match the backup-time SHA-256 seal.';
    }
    if (!hasManifest) {
      return 'This backup was created before integrity sealing or its manifest is missing.';
    }
    final pieces = <String>[];
    if (!manifestMatchesSeal) {
      pieces.add('manifest hash changed');
    }
    if (missingFiles.isNotEmpty) {
      pieces.add(
        '${missingFiles.length} missing file${missingFiles.length == 1 ? '' : 's'}',
      );
    }
    if (changedFiles.isNotEmpty) {
      pieces.add(
        '${changedFiles.length} changed file${changedFiles.length == 1 ? '' : 's'}',
      );
    }
    if (extraFiles.isNotEmpty) {
      pieces.add(
        '${extraFiles.length} unexpected file${extraFiles.length == 1 ? '' : 's'}',
      );
    }
    if (error != null) {
      pieces.add(error!);
    }
    if (!hasLocalSeal) {
      pieces.add(
        'local seal ledger entry is missing; manifest creation time cannot be corroborated locally',
      );
    }
    return pieces.isEmpty ? 'Integrity check needs review.' : pieces.join('; ');
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
    this.comments = const [],
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
  final List<RenderComment> comments;
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
    'comments': comments.map((comment) => comment.toJson()).toList(),
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
      comments: (json['comments'] as List<Object?>? ?? const [])
          .cast<Map<String, Object?>>()
          .map(RenderComment.fromJson)
          .toList(),
      attachmentName: json['attachmentName'] as String?,
      attachmentContentType: json['attachmentContentType'] as String?,
      attachmentSize: json['attachmentSize'] as int?,
      attachmentOriginalPath: json['attachmentOriginalPath'] as String?,
    );
  }
}

class RenderComment {
  const RenderComment({
    required this.id,
    required this.text,
    required this.createdAt,
    this.author,
  });

  final int id;
  final String text;
  final String createdAt;
  final String? author;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'createdAt': createdAt,
    'author': author,
  };

  static RenderComment fromJson(Map<String, Object?> json) {
    return RenderComment(
      id: json['id'] as int? ?? 0,
      text: json['text'] as String? ?? '',
      createdAt: json['createdAt'] as String? ?? '',
      author: json['author'] as String?,
    );
  }
}
