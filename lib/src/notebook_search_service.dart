import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'backup_service.dart';
import 'search_models.dart';

class NotebookSearchService {
  NotebookSearchService(this.backupService);

  static const _fallbackMethodSummary =
      'Local fuzzy fallback uses on-device BM25 relevance, phrase boosts, typo-tolerant token matching, and character n-gram similarity.';

  final BackupService backupService;

  Future<NotebookSearchResult> search(String query) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) {
      return const NotebookSearchResult(
        query: '',
        answer: 'Enter a notebook search question.',
        hits: [],
        usedOpenAi: false,
      );
    }

    final chunks = await backupService.loadAllSearchChunks();
    if (chunks.isEmpty) {
      return NotebookSearchResult(
        query: cleanQuery,
        answer: 'No readable notebook copies are available yet.',
        hits: const [],
        usedOpenAi: false,
      );
    }

    final localHits = _rankLocal(cleanQuery, chunks, limit: 12);
    final settings = await backupService.loadOpenAiSearchSettings();
    final hasOpenAi = settings != null && settings.hasApiKey;
    if (!hasOpenAi) {
      return NotebookSearchResult(
        query: cleanQuery,
        answer: _localAnswer(localHits, missingOpenAiKey: true),
        hits: localHits,
        usedOpenAi: false,
      );
    }

    final contextHits = _contextHits(cleanQuery, chunks);
    try {
      final answer = await _askOpenAi(
        query: cleanQuery,
        hits: contextHits,
        settings: settings,
      );
      return NotebookSearchResult(
        query: cleanQuery,
        answer: answer.isEmpty ? _localAnswer(localHits) : answer,
        hits: contextHits.take(12).toList(),
        usedOpenAi: answer.isNotEmpty,
      );
    } catch (error) {
      return NotebookSearchResult(
        query: cleanQuery,
        answer: _localAnswer(localHits, fallbackReason: 'OpenAI unavailable'),
        hits: localHits,
        usedOpenAi: false,
        warning:
            'OpenAI search unavailable; showing local fuzzy fallback. ${_briefError(error)}',
      );
    }
  }

  List<NotebookSearchHit> _contextHits(
    String query,
    List<NotebookSearchChunk> chunks,
  ) {
    final localHits = _rankLocal(query, chunks, limit: 24);
    if (localHits.any((hit) => hit.score > 0)) {
      return localHits;
    }
    final latest = [...chunks]
      ..sort((a, b) => b.backupCreatedAt.compareTo(a.backupCreatedAt));
    return latest
        .take(24)
        .map(
          (chunk) => NotebookSearchHit(
            chunk: chunk,
            score: 0,
            snippet: _snippet(chunk.text, const []),
          ),
        )
        .toList();
  }

  List<NotebookSearchHit> _rankLocal(
    String query,
    List<NotebookSearchChunk> chunks, {
    required int limit,
  }) {
    final tokens = _tokens(query);
    final queryText = _normalize(query);
    final queryTrigrams = _trigrams(queryText);
    final profiles = chunks.map(_SearchProfile.new).toList();
    final documentFrequency = <String, int>{};
    var totalLength = 0;
    for (final profile in profiles) {
      totalLength += profile.termCount;
      for (final token in profile.termCounts.keys) {
        documentFrequency[token] = (documentFrequency[token] ?? 0) + 1;
      }
    }
    final averageLength = profiles.isEmpty
        ? 1.0
        : totalLength / profiles.length;
    final hits = <NotebookSearchHit>[];
    for (final profile in profiles) {
      final chunk = profile.chunk;
      var score = _bm25(
        tokens,
        profile.termCounts,
        profile.termCount,
        averageLength,
        documentFrequency,
        profiles.length,
      );
      score += _fieldScore(tokens, profile);
      score += _phraseScore(queryText, profile);
      score += _trigramContainment(queryTrigrams, profile.trigrams) * 4;
      if (score > 0) {
        hits.add(
          NotebookSearchHit(
            chunk: chunk,
            score: score,
            snippet: _snippet(chunk.text, tokens),
          ),
        );
      }
    }
    hits.sort((a, b) {
      final scoreCompare = b.score.compareTo(a.score);
      if (scoreCompare != 0) {
        return scoreCompare;
      }
      return b.chunk.backupCreatedAt.compareTo(a.chunk.backupCreatedAt);
    });
    return hits.take(limit).toList();
  }

  double _bm25(
    List<String> queryTokens,
    Map<String, int> termCounts,
    int documentLength,
    double averageLength,
    Map<String, int> documentFrequency,
    int documentCount,
  ) {
    const k1 = 1.2;
    const b = 0.75;
    var score = 0.0;
    for (final token in queryTokens) {
      final frequency = termCounts[token] ?? 0;
      if (frequency == 0) {
        continue;
      }
      final containingDocs = documentFrequency[token] ?? 0;
      final idf = log(
        1 + (documentCount - containingDocs + 0.5) / (containingDocs + 0.5),
      );
      final denominator =
          frequency +
          k1 * (1 - b + b * (documentLength / max(averageLength, 1)));
      score += idf * ((frequency * (k1 + 1)) / denominator);
    }
    return score * 6;
  }

  double _fieldScore(List<String> tokens, _SearchProfile profile) {
    var score = 0.0;
    for (final token in tokens) {
      if (profile.title.contains(token)) {
        score += 7;
      } else {
        score += _bestTokenSimilarity(token, profile.titleTokens) * 2.5;
      }
      if (profile.path.contains(token)) {
        score += 4;
      } else {
        score += _bestTokenSimilarity(token, profile.pathTokens) * 1.8;
      }
      if (profile.attachments.contains(token)) {
        score += 3;
      } else {
        score += _bestTokenSimilarity(token, profile.attachmentTokens) * 1.5;
      }
      if (profile.termCounts.containsKey(token)) {
        score += 1;
      } else {
        score += _bestTokenSimilarity(token, profile.uniqueTokens) * 1.2;
      }
    }
    return score;
  }

  double _phraseScore(String queryText, _SearchProfile profile) {
    if (queryText.isEmpty) {
      return 0;
    }
    var score = 0.0;
    if (profile.title.contains(queryText)) {
      score += 14;
    }
    if (profile.path.contains(queryText)) {
      score += 8;
    }
    if (profile.attachments.contains(queryText)) {
      score += 6;
    }
    if (profile.text.contains(queryText)) {
      score += 10;
    }
    return score;
  }

  double _bestTokenSimilarity(String token, Set<String> candidates) {
    if (token.length < 4 || candidates.isEmpty) {
      return 0;
    }
    var best = 0.0;
    final first = token.codeUnitAt(0);
    for (final candidate in candidates) {
      if ((candidate.length - token.length).abs() > 3) {
        continue;
      }
      if (candidate.codeUnitAt(0) != first) {
        continue;
      }
      final similarity = _editSimilarity(token, candidate);
      if (similarity > best) {
        best = similarity;
        if (best == 1) {
          break;
        }
      }
    }
    return best >= 0.78 ? best : 0;
  }

  double _editSimilarity(String a, String b) {
    if (a == b) {
      return 1;
    }
    if (a.isEmpty || b.isEmpty) {
      return 0;
    }
    final distance = _levenshtein(a, b);
    return 1 - distance / max(a.length, b.length);
  }

  int _levenshtein(String a, String b) {
    final previous = List<int>.generate(b.length + 1, (index) => index);
    final current = List<int>.filled(b.length + 1, 0);
    for (var i = 0; i < a.length; i++) {
      current[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        final cost = a.codeUnitAt(i) == b.codeUnitAt(j) ? 0 : 1;
        current[j + 1] = min(
          min(current[j] + 1, previous[j + 1] + 1),
          previous[j] + cost,
        );
      }
      for (var j = 0; j < previous.length; j++) {
        previous[j] = current[j];
      }
    }
    return previous[b.length];
  }

  double _trigramContainment(Set<String> query, Set<String> document) {
    if (query.isEmpty || document.isEmpty) {
      return 0;
    }
    var overlap = 0;
    for (final trigram in query) {
      if (document.contains(trigram)) {
        overlap++;
      }
    }
    return overlap / query.length;
  }

  List<String> _tokens(String value) {
    final raw = RegExp(r"[a-zA-Z0-9][a-zA-Z0-9._'-]+")
        .allMatches(_normalize(value))
        .map((match) => match.group(0)!)
        .where((token) => token.length > 1)
        .toSet()
        .toList();
    final filtered = raw
        .where((token) => !_stopWords.contains(token))
        .toSet()
        .toList();
    return filtered.isEmpty ? raw : filtered;
  }

  String _normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9._'\-\s]+"), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Set<String> _trigrams(String value) {
    final padded = '  ${_normalize(value)}  ';
    if (padded.trim().length < 3) {
      return const {};
    }
    final grams = <String>{};
    for (var index = 0; index <= padded.length - 3; index++) {
      final gram = padded.substring(index, index + 3);
      if (gram.trim().isNotEmpty) {
        grams.add(gram);
      }
    }
    return grams;
  }

  String _snippet(String text, List<String> tokens) {
    final collapsed = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.length <= 320) {
      return collapsed;
    }
    final lower = collapsed.toLowerCase();
    var index = -1;
    for (final token in tokens) {
      index = lower.indexOf(token);
      if (index >= 0) {
        break;
      }
    }
    final start = index < 0 ? 0 : max(0, index - 120);
    final end = min(collapsed.length, start + 320);
    final prefix = start > 0 ? '...' : '';
    final suffix = end < collapsed.length ? '...' : '';
    return '$prefix${collapsed.substring(start, end)}$suffix';
  }

  String _localAnswer(
    List<NotebookSearchHit> hits, {
    bool missingOpenAiKey = false,
    String? fallbackReason,
  }) {
    if (hits.isEmpty) {
      return missingOpenAiKey
          ? 'No local fuzzy matches found. Add an OpenAI API key in Search Settings for natural-language answers.'
          : 'No local fuzzy matches found.';
    }
    final buffer = StringBuffer();
    if (fallbackReason == null) {
      buffer.write('Local fuzzy search found ${hits.length} likely match');
    } else {
      buffer.write(
        '$fallbackReason. Local fuzzy fallback found ${hits.length} likely match',
      );
    }
    if (hits.length != 1) {
      buffer.write('es');
    }
    buffer.writeln('.');
    buffer.writeln(_fallbackMethodSummary);
    if (missingOpenAiKey) {
      buffer.writeln(
        'Add an OpenAI API key in Search Settings for natural-language answers.',
      );
    }
    buffer.writeln();
    buffer.writeln('Best matches:');
    for (final hit in hits.take(3)) {
      buffer
        ..writeln('- ${hit.chunk.citation}')
        ..writeln('  ${_truncate(hit.snippet, 180)}');
    }
    return buffer.toString().trim();
  }

  Future<String> _askOpenAi({
    required String query,
    required List<NotebookSearchHit> hits,
    required OpenAiSearchSettings settings,
  }) async {
    final client = HttpClient();
    try {
      final request = await client
          .postUrl(Uri.https('api.openai.com', '/v1/responses'))
          .timeout(const Duration(seconds: 20));
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${settings.apiKey}')
        ..set(HttpHeaders.contentTypeHeader, ContentType.json.mimeType);
      final body = jsonEncode({
        'model': settings.model.trim().isEmpty
            ? OpenAiSearchSettings.defaultModel
            : settings.model.trim(),
        'reasoning': {'effort': 'low'},
        'text': {'verbosity': 'low'},
        'input': [
          {
            'role': 'system',
            'content':
                'Answer questions about backed-up lab notebooks using only the supplied excerpts. Cite excerpts with bracket numbers like [1]. If the excerpts do not contain the answer, say what is missing. Never ask for or reveal credentials.',
          },
          {
            'role': 'user',
            'content':
                'Question: $query\n\nBacked-up notebook excerpts:\n${_openAiContext(hits)}',
          },
        ],
      });
      request.write(body);
      final response = await request.close().timeout(
        const Duration(seconds: 90),
      );
      final responseBody = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('HTTP ${response.statusCode}: $_redact(responseBody)');
      }
      final json = jsonDecode(responseBody);
      if (json is! Map<String, Object?>) {
        return '';
      }
      return _extractResponseText(json).trim();
    } finally {
      client.close(force: true);
    }
  }

  String _openAiContext(List<NotebookSearchHit> hits) {
    final buffer = StringBuffer();
    for (var index = 0; index < hits.length; index++) {
      final hit = hits[index];
      final chunk = hit.chunk;
      buffer
        ..writeln('[${index + 1}] Notebook: ${chunk.notebookName}')
        ..writeln('Backup: ${chunk.backupCreatedAt.toIso8601String()}')
        ..writeln('Page: ${chunk.path}')
        ..writeln('Attachments: ${chunk.attachments.join('; ')}')
        ..writeln(_truncate(chunk.text, 3000))
        ..writeln();
    }
    return buffer.toString();
  }

  String _truncate(String value, int maxChars) {
    if (value.length <= maxChars) {
      return value;
    }
    return '${value.substring(0, maxChars)}...';
  }

  String _extractResponseText(Map<String, Object?> json) {
    final outputText = json['output_text'];
    if (outputText is String && outputText.isNotEmpty) {
      return outputText;
    }
    final pieces = <String>[];
    void walk(Object? value) {
      if (value is List<Object?>) {
        for (final item in value) {
          walk(item);
        }
        return;
      }
      if (value is Map<String, Object?>) {
        if (value['type'] == 'output_text' && value['text'] is String) {
          pieces.add(value['text'] as String);
          return;
        }
        for (final entry in value.entries) {
          if (entry.key == 'output_text') {
            continue;
          }
          walk(entry.value);
        }
      }
    }

    walk(json['output']);
    return pieces.join('\n').trim();
  }

  String _redact(String value) {
    return value.replaceAll(RegExp(r'sk-[A-Za-z0-9_-]+'), 'sk-...');
  }

  String _briefError(Object error) {
    final redacted = _redact(error.toString()).replaceAll(RegExp(r'\s+'), ' ');
    return redacted.length <= 160
        ? redacted
        : '${redacted.substring(0, 160)}...';
  }

  static const _stopWords = {
    'about',
    'after',
    'again',
    'also',
    'and',
    'are',
    'because',
    'before',
    'between',
    'can',
    'could',
    'did',
    'does',
    'for',
    'from',
    'has',
    'have',
    'how',
    'into',
    'not',
    'show',
    'that',
    'the',
    'their',
    'there',
    'this',
    'was',
    'were',
    'what',
    'when',
    'where',
    'which',
    'with',
    'without',
  };
}

class _SearchProfile {
  _SearchProfile(this.chunk)
    : text = _sharedNormalize(chunk.text),
      title = _sharedNormalize(chunk.pageTitle),
      path = _sharedNormalize(chunk.path),
      attachments = _sharedNormalize(chunk.attachments.join(' ')) {
    titleTokens = _sharedTokens(title);
    pathTokens = _sharedTokens(path);
    attachmentTokens = _sharedTokens(attachments);
    final weightedTokens = [
      ..._sharedTokens(text),
      for (var i = 0; i < 3; i++) ...titleTokens,
      for (var i = 0; i < 2; i++) ...pathTokens,
      for (var i = 0; i < 2; i++) ...attachmentTokens,
    ];
    termCounts = <String, int>{};
    for (final token in weightedTokens) {
      termCounts[token] = (termCounts[token] ?? 0) + 1;
    }
    termCount = max(weightedTokens.length, 1);
    uniqueTokens = termCounts.keys.toSet();
    trigrams = _sharedTrigrams('$title $path $attachments $text');
  }

  final NotebookSearchChunk chunk;
  final String text;
  final String title;
  final String path;
  final String attachments;
  late final Set<String> titleTokens;
  late final Set<String> pathTokens;
  late final Set<String> attachmentTokens;
  late final Map<String, int> termCounts;
  late final int termCount;
  late final Set<String> uniqueTokens;
  late final Set<String> trigrams;
}

String _sharedNormalize(String value) {
  return value
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9._'\-\s]+"), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

Set<String> _sharedTokens(String value) {
  return RegExp(r"[a-zA-Z0-9][a-zA-Z0-9._'-]+")
      .allMatches(_sharedNormalize(value))
      .map((match) => match.group(0)!)
      .where((token) => token.length > 1)
      .toSet();
}

Set<String> _sharedTrigrams(String value) {
  final padded = '  ${_sharedNormalize(value)}  ';
  if (padded.trim().length < 3) {
    return const {};
  }
  final grams = <String>{};
  for (var index = 0; index <= padded.length - 3; index++) {
    final gram = padded.substring(index, index + 3);
    if (gram.trim().isNotEmpty) {
      grams.add(gram);
    }
  }
  return grams;
}
