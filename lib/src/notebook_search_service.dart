import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'backup_service.dart';
import 'search_models.dart';

class NotebookSearchService {
  NotebookSearchService(this.backupService);

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
        answer: _localAnswer(localHits),
        hits: localHits,
        usedOpenAi: false,
        warning: 'OpenAI search failed: $error',
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
    final hits = <NotebookSearchHit>[];
    for (final chunk in chunks) {
      final text = chunk.text.toLowerCase();
      final title = chunk.pageTitle.toLowerCase();
      final path = chunk.path.toLowerCase();
      var score = 0.0;
      for (final token in tokens) {
        final matches = _countMatches(text, token);
        if (matches > 0) {
          score += min(matches, 8).toDouble();
        }
        if (title.contains(token)) {
          score += 5;
        }
        if (path.contains(token)) {
          score += 3;
        }
        if (chunk.attachments.any(
          (value) => value.toLowerCase().contains(token),
        )) {
          score += 2;
        }
      }
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

  int _countMatches(String text, String token) {
    var count = 0;
    var start = 0;
    while (true) {
      final index = text.indexOf(token, start);
      if (index < 0) {
        return count;
      }
      count++;
      start = index + token.length;
    }
  }

  List<String> _tokens(String value) {
    final matches = RegExp(r"[a-zA-Z0-9][a-zA-Z0-9._'-]+")
        .allMatches(value.toLowerCase())
        .map((match) => match.group(0)!)
        .where((token) => token.length > 1)
        .toSet()
        .toList();
    return matches;
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
  }) {
    if (hits.isEmpty) {
      return missingOpenAiKey
          ? 'No local keyword matches found. Add an OpenAI API key in Search Settings for natural-language answers.'
          : 'No local keyword matches found.';
    }
    final top = hits.first.chunk;
    final suffix = missingOpenAiKey
        ? ' Add an OpenAI API key in Search Settings for natural-language answers.'
        : '';
    return 'Top local match: ${top.notebookName} / ${top.path}.$suffix';
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
}
