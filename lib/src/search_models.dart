class OpenAiSearchSettings {
  const OpenAiSearchSettings({required this.apiKey, this.model = defaultModel});

  static const defaultModel = 'gpt-5.5';

  final String apiKey;
  final String model;

  bool get hasApiKey => apiKey.trim().isNotEmpty;

  OpenAiSearchSettings copyWith({String? apiKey, String? model}) {
    return OpenAiSearchSettings(
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
    );
  }
}

enum NotebookSearchScope {
  all,
  pageText,
  attachments,
  comments;

  String get label {
    return switch (this) {
      NotebookSearchScope.all => 'All',
      NotebookSearchScope.pageText => 'Text',
      NotebookSearchScope.attachments => 'Attachments',
      NotebookSearchScope.comments => 'Comments',
    };
  }
}

class NotebookSearchFilters {
  const NotebookSearchFilters({
    this.scope = NotebookSearchScope.all,
    this.exactPhrase = false,
    this.verifiedOnly = false,
  });

  final NotebookSearchScope scope;
  final bool exactPhrase;
  final bool verifiedOnly;

  bool get isDefault =>
      scope == NotebookSearchScope.all && !exactPhrase && !verifiedOnly;

  String get summary {
    final pieces = <String>[
      scope.label,
      if (exactPhrase) 'exact phrase',
      if (verifiedOnly) 'verified backups',
    ];
    return pieces.join(' · ');
  }

  NotebookSearchFilters copyWith({
    NotebookSearchScope? scope,
    bool? exactPhrase,
    bool? verifiedOnly,
  }) {
    return NotebookSearchFilters(
      scope: scope ?? this.scope,
      exactPhrase: exactPhrase ?? this.exactPhrase,
      verifiedOnly: verifiedOnly ?? this.verifiedOnly,
    );
  }
}

class NotebookSearchChunk {
  const NotebookSearchChunk({
    required this.id,
    required this.backupId,
    required this.notebookName,
    required this.backupCreatedAt,
    required this.nodeId,
    required this.pageTitle,
    required this.path,
    required this.text,
    this.attachments = const [],
    this.commentCount = 0,
    this.partCount = 0,
  });

  final String id;
  final String backupId;
  final String notebookName;
  final DateTime backupCreatedAt;
  final int nodeId;
  final String pageTitle;
  final String path;
  final String text;
  final List<String> attachments;
  final int commentCount;
  final int partCount;

  String get citation => '$notebookName / $path';

  Map<String, Object?> toJson() => {
    'id': id,
    'backupId': backupId,
    'notebookName': notebookName,
    'backupCreatedAt': backupCreatedAt.toIso8601String(),
    'nodeId': nodeId,
    'pageTitle': pageTitle,
    'path': path,
    'text': text,
    'attachments': attachments,
    'commentCount': commentCount,
    'partCount': partCount,
  };

  static NotebookSearchChunk fromJson(Map<String, Object?> json) {
    return NotebookSearchChunk(
      id: json['id'] as String? ?? '',
      backupId: json['backupId'] as String? ?? '',
      notebookName: json['notebookName'] as String? ?? 'Untitled notebook',
      backupCreatedAt:
          DateTime.tryParse(json['backupCreatedAt'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      nodeId: json['nodeId'] as int? ?? 0,
      pageTitle: json['pageTitle'] as String? ?? 'Untitled page',
      path: json['path'] as String? ?? '',
      text: json['text'] as String? ?? '',
      attachments: (json['attachments'] as List<Object?>? ?? const [])
          .map((value) => value.toString())
          .toList(),
      commentCount: json['commentCount'] as int? ?? 0,
      partCount: json['partCount'] as int? ?? 0,
    );
  }
}

class NotebookSearchHit {
  const NotebookSearchHit({
    required this.chunk,
    required this.score,
    required this.snippet,
  });

  final NotebookSearchChunk chunk;
  final double score;
  final String snippet;
}

class NotebookSearchResult {
  const NotebookSearchResult({
    required this.query,
    required this.answer,
    required this.hits,
    required this.usedOpenAi,
    this.filters = const NotebookSearchFilters(),
    this.warning,
  });

  final String query;
  final String answer;
  final List<NotebookSearchHit> hits;
  final bool usedOpenAi;
  final NotebookSearchFilters filters;
  final String? warning;
}
