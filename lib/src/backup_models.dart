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

enum BackupOutcomeStatus {
  success,
  skipped;

  String get label {
    return switch (this) {
      BackupOutcomeStatus.success => 'Backed up',
      BackupOutcomeStatus.skipped => 'Skipped',
    };
  }
}

enum BackupFailureCategory {
  none,
  notOwner,
  authorization,
  storage,
  extraction,
  verification,
  network,
  setup,
  unknown;

  String get label {
    return switch (this) {
      BackupFailureCategory.none => 'None',
      BackupFailureCategory.notOwner => 'Not owner',
      BackupFailureCategory.authorization => 'Authorization',
      BackupFailureCategory.storage => 'Storage',
      BackupFailureCategory.extraction => 'Extraction',
      BackupFailureCategory.verification => 'Verification',
      BackupFailureCategory.network => 'Network',
      BackupFailureCategory.setup => 'Setup',
      BackupFailureCategory.unknown => 'Unknown',
    };
  }
}

class BackupNotebookOutcome {
  const BackupNotebookOutcome({
    required this.notebookName,
    required this.status,
    required this.category,
    required this.message,
    this.notebookNbid,
    this.nextAction,
    this.backupRecordId,
    this.queueIndex,
    this.totalQueueCount,
    this.startedAt,
    this.completedAt,
    this.pageCount,
    this.archiveBytes,
    this.verifiedOriginalAttachmentCount,
    this.expectedOriginalAttachmentCount,
  });

  final String notebookName;
  final String? notebookNbid;
  final BackupOutcomeStatus status;
  final BackupFailureCategory category;
  final String message;
  final String? nextAction;
  final String? backupRecordId;
  final int? queueIndex;
  final int? totalQueueCount;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final int? pageCount;
  final int? archiveBytes;
  final int? verifiedOriginalAttachmentCount;
  final int? expectedOriginalAttachmentCount;

  bool get isSuccess => status == BackupOutcomeStatus.success;

  bool get isRetryable =>
      !isSuccess && category != BackupFailureCategory.notOwner;

  Duration? get duration {
    final start = startedAt;
    final end = completedAt;
    if (start == null || end == null) {
      return null;
    }
    return end.difference(start);
  }

  String get summary {
    if (isSuccess) {
      final originals =
          verifiedOriginalAttachmentCount == null ||
              expectedOriginalAttachmentCount == null
          ? null
          : '$verifiedOriginalAttachmentCount/$expectedOriginalAttachmentCount originals';
      final pieces = [if (pageCount != null) '$pageCount pages', ?originals];
      return pieces.isEmpty ? message : pieces.join(' · ');
    }
    return nextAction == null ? message : '$message $nextAction';
  }

  Map<String, Object?> toJson() => {
    'notebookName': notebookName,
    'notebookNbid': notebookNbid,
    'status': status.name,
    'category': category.name,
    'message': message,
    'nextAction': nextAction,
    'backupRecordId': backupRecordId,
    'queueIndex': queueIndex,
    'totalQueueCount': totalQueueCount,
    'startedAt': startedAt?.toIso8601String(),
    'completedAt': completedAt?.toIso8601String(),
    'durationMs': duration?.inMilliseconds,
    'pageCount': pageCount,
    'archiveBytes': archiveBytes,
    'verifiedOriginalAttachmentCount': verifiedOriginalAttachmentCount,
    'expectedOriginalAttachmentCount': expectedOriginalAttachmentCount,
  };

  static BackupNotebookOutcome fromJson(Map<String, Object?> json) {
    return BackupNotebookOutcome(
      notebookName: json['notebookName'] as String? ?? 'Notebook',
      notebookNbid: json['notebookNbid'] as String?,
      status: BackupOutcomeStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => BackupOutcomeStatus.skipped,
      ),
      category: BackupFailureCategory.values.firstWhere(
        (value) => value.name == json['category'],
        orElse: () => BackupFailureCategory.unknown,
      ),
      message: json['message'] as String? ?? '',
      nextAction: json['nextAction'] as String?,
      backupRecordId: json['backupRecordId'] as String?,
      queueIndex: json['queueIndex'] as int?,
      totalQueueCount: json['totalQueueCount'] as int?,
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? ''),
      completedAt: DateTime.tryParse(json['completedAt'] as String? ?? ''),
      pageCount: json['pageCount'] as int?,
      archiveBytes: json['archiveBytes'] as int?,
      verifiedOriginalAttachmentCount:
          json['verifiedOriginalAttachmentCount'] as int?,
      expectedOriginalAttachmentCount:
          json['expectedOriginalAttachmentCount'] as int?,
    );
  }
}

class BackupRunManifest {
  const BackupRunManifest({
    required this.id,
    required this.createdAt,
    required this.completedAt,
    required this.totalNotebookCount,
    required this.outcomes,
    required this.records,
    required this.log,
    this.runMode = 'full',
    this.retryOfRunId,
  });

  final String id;
  final DateTime createdAt;
  final DateTime completedAt;
  final int totalNotebookCount;
  final List<BackupNotebookOutcome> outcomes;
  final List<BackupRecord> records;
  final List<String> log;
  final String runMode;
  final String? retryOfRunId;

  int get successCount => outcomes.where((outcome) => outcome.isSuccess).length;

  int get skippedCount => outcomes.length - successCount;

  bool get hasFailures => skippedCount > 0;

  int get retryableFailureCount =>
      outcomes.where((outcome) => outcome.isRetryable).length;

  bool get hasRetryableFailures => retryableFailureCount > 0;

  List<BackupNotebookOutcome> get failedOutcomes =>
      outcomes.where((outcome) => !outcome.isSuccess).toList();

  String get noSuccessfulBackupsMessage {
    final failures = failedOutcomes;
    if (failures.isEmpty) {
      return 'No notebooks were backed up because no notebooks were selected.';
    }
    final categories = failures.map((outcome) => outcome.category).toSet()
      ..remove(BackupFailureCategory.none);
    final onlyCategory = categories.length == 1
        ? categories.single
        : BackupFailureCategory.none;

    return switch (onlyCategory) {
      BackupFailureCategory.notOwner =>
        'No notebooks could be backed up with the current user rights. At NIH/NICHD, full-size notebook backup is owner-only, and lab notebook owners are lab chiefs/PIs.',
      BackupFailureCategory.authorization =>
        'No notebooks could be backed up because LabArchives authorization failed. Reconnect LabArchives credentials and try again.',
      BackupFailureCategory.storage =>
        'No notebooks could be backed up because local storage failed. Check free disk space and folder permissions, then try again.',
      BackupFailureCategory.extraction =>
        'No notebooks could be backed up because the downloaded archives could not be extracted. Install or repair the local unzip tools and try again.',
      BackupFailureCategory.verification =>
        'No notebooks could be backed up because full-size content verification failed. Review the latest run details before relying on this backup.',
      BackupFailureCategory.network =>
        'No notebooks could be backed up because LabArchives could not be reached reliably. Check the network or VPN connection and try again.',
      BackupFailureCategory.setup =>
        'No notebooks could be backed up because local setup is incomplete. Finish first-run setup and try again.',
      _ => _mixedFailureMessage(failures, categories),
    };
  }

  String get createdAtLabel {
    final local = createdAt.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  String get summary {
    final pieces = <String>[
      '$successCount backed up',
      if (skippedCount > 0) '$skippedCount skipped',
    ];
    return pieces.join(' · ');
  }

  Map<String, Object?> toJson() => {
    'version': 3,
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'completedAt': completedAt.toIso8601String(),
    'totalNotebookCount': totalNotebookCount,
    'successCount': successCount,
    'skippedCount': skippedCount,
    'runMode': runMode,
    'retryOfRunId': retryOfRunId,
    'outcomes': outcomes.map((outcome) => outcome.toJson()).toList(),
    'records': records.map((record) => record.toJson()).toList(),
    'log': log,
  };

  static BackupRunManifest fromJson(Map<String, Object?> json) {
    final records = (json['records'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(BackupRecord.fromJson)
        .toList();
    final outcomes = (json['outcomes'] as List<Object?>? ?? const [])
        .whereType<Map<String, Object?>>()
        .map(BackupNotebookOutcome.fromJson)
        .toList();
    return BackupRunManifest(
      id: json['id'] as String? ?? '',
      createdAt: DateTime.parse(json['createdAt'] as String),
      completedAt:
          DateTime.tryParse(json['completedAt'] as String? ?? '') ??
          DateTime.parse(json['createdAt'] as String),
      totalNotebookCount:
          json['totalNotebookCount'] as int? ??
          json['notebookCount'] as int? ??
          records.length,
      outcomes: outcomes.isEmpty
          ? records
                .map(
                  (record) => BackupNotebookOutcome(
                    notebookName: record.notebookName,
                    status: BackupOutcomeStatus.success,
                    category: BackupFailureCategory.none,
                    message: 'Backed up successfully.',
                    backupRecordId: record.id,
                    pageCount: record.pageCount,
                    archiveBytes: record.contentVerification?.archiveBytes,
                    startedAt: record.createdAt,
                    completedAt: record.createdAt,
                    verifiedOriginalAttachmentCount: record
                        .contentVerification
                        ?.verifiedOriginalAttachmentCount,
                    expectedOriginalAttachmentCount: record
                        .contentVerification
                        ?.expectedOriginalAttachmentCount,
                  ),
                )
                .toList()
          : outcomes,
      records: records,
      log: (json['log'] as List<Object?>? ?? const [])
          .map((value) => value.toString())
          .toList(),
      runMode: json['runMode'] as String? ?? 'full',
      retryOfRunId: json['retryOfRunId'] as String?,
    );
  }
}

String _mixedFailureMessage(
  List<BackupNotebookOutcome> failures,
  Set<BackupFailureCategory> categories,
) {
  final labels = categories.isEmpty
      ? 'Unknown'
      : (categories.toList()..sort((a, b) => a.label.compareTo(b.label)))
            .map((category) => category.label)
            .join(', ');
  String? nextAction;
  for (final outcome in failures) {
    final value = outcome.nextAction?.trim();
    if (value != null && value.isNotEmpty) {
      nextAction = value;
      break;
    }
  }
  return [
    'No notebooks could be backed up. Failure categories: $labels.',
    ?nextAction,
  ].join(' ');
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

  Map<String, Object?> toJson() => {
    'backupId': backupId,
    'checkedAt': checkedAt.toIso8601String(),
    'hasManifest': hasManifest,
    'hasLocalSeal': hasLocalSeal,
    'manifestPath': manifestPath,
    'manifestSha256': manifestSha256,
    'sealedManifestSha256': sealedManifestSha256,
    'checkedFileCount': checkedFileCount,
    'checkedBytes': checkedBytes,
    'missingFiles': missingFiles,
    'changedFiles': changedFiles,
    'extraFiles': extraFiles,
    'error': error,
    'isVerified': isVerified,
    'statusTitle': statusTitle,
    'summary': summary,
  };
}

class BackupAuditExport {
  const BackupAuditExport({
    required this.generatedAt,
    required this.markdownPath,
    required this.jsonPath,
    required this.csvPath,
    required this.hashAnchorPath,
    required this.integrityCheck,
  });

  final DateTime generatedAt;
  final String markdownPath;
  final String jsonPath;
  final String csvPath;
  final String hashAnchorPath;
  final BackupIntegrityCheck integrityCheck;

  Map<String, Object?> toJson() => {
    'generatedAt': generatedAt.toIso8601String(),
    'markdownPath': markdownPath,
    'jsonPath': jsonPath,
    'csvPath': csvPath,
    'hashAnchorPath': hashAnchorPath,
    'integrityCheck': integrityCheck.toJson(),
  };
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
    this.sourceLayout = 'json',
  });

  final String name;
  final DateTime createdAt;
  final String archivePath;
  final List<RenderNode> nodes;
  final String sourceLayout;

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
    'sourceLayout': sourceLayout,
    'nodes': nodes.map((node) => node.toJson()).toList(),
  };

  static RenderNotebook fromJson(Map<String, Object?> json) {
    final rawNodes = json['nodes'] as List<Object?>? ?? const [];
    return RenderNotebook(
      name: json['name'] as String? ?? 'Untitled notebook',
      createdAt: DateTime.parse(json['createdAt'] as String),
      archivePath: json['archivePath'] as String? ?? '',
      sourceLayout: json['sourceLayout'] as String? ?? 'json',
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
    this.attachmentThumbnailPath,
    this.attachmentVersion,
    this.attachmentOriginalVersion,
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
  final String? attachmentThumbnailPath;
  final int? attachmentVersion;
  final int? attachmentOriginalVersion;

  bool get isAttachment => attachmentName != null && attachmentName!.isNotEmpty;

  String get attachmentSummary {
    final pieces = <String>[];
    if (attachmentContentType != null && attachmentContentType!.isNotEmpty) {
      pieces.add(attachmentContentType!);
    }
    if (attachmentSize != null) {
      pieces.add('${attachmentSize!} bytes');
    }
    if (attachmentOriginalVersion != null) {
      pieces.add('original v$attachmentOriginalVersion');
    } else if (attachmentVersion != null) {
      pieces.add('entry v$attachmentVersion');
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
    'attachmentThumbnailPath': attachmentThumbnailPath,
    'attachmentVersion': attachmentVersion,
    'attachmentOriginalVersion': attachmentOriginalVersion,
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
      attachmentThumbnailPath: json['attachmentThumbnailPath'] as String?,
      attachmentVersion: json['attachmentVersion'] as int?,
      attachmentOriginalVersion: json['attachmentOriginalVersion'] as int?,
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
