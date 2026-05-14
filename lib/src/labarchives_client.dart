import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'backup_models.dart';

class LabArchivesClient {
  LabArchivesClient({
    required this.accessId,
    required this.accessKey,
    required this.uid,
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? HttpClient();

  final String accessId;
  final String accessKey;
  final String uid;
  final HttpClient _httpClient;

  Future<File> downloadNotebookBackup({
    required NotebookSummary notebook,
    required File destination,
  }) async {
    final uri = _elnUri(
      apiClass: 'notebooks',
      method: 'notebook_backup',
      params: {'uid': uid, 'nbid': notebook.nbid, 'json': 'true'},
    );
    final request = await _httpClient.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'elnla-backup/0.1');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      final body = await utf8.decodeStream(response);
      throw LabArchivesException(
        'Backup failed for ${notebook.name}: HTTP ${response.statusCode} ${_safeError(body)}',
      );
    }
    await destination.parent.create(recursive: true);
    final sink = destination.openWrite();
    await response.pipe(sink);
    return destination;
  }

  Uri _elnUri({
    required String apiClass,
    required String method,
    required Map<String, String> params,
  }) {
    final expires = '${DateTime.now().millisecondsSinceEpoch}';
    final sig = _signature(method, expires);
    return Uri.https('api.labarchives-gov.com', '/api/$apiClass/$method', {
      ...params,
      'akid': accessId,
      'expires': expires,
      'sig': sig,
    });
  }

  String _signature(String method, String expires) {
    final key = utf8.encode(accessKey);
    final message = utf8.encode('$accessId$method$expires');
    return base64Encode(Hmac(sha1, key).convert(message).bytes);
  }

  String _safeError(String body) {
    final code = RegExp(
      r'<error-code[^>]*>(.*?)</error-code>',
      dotAll: true,
    ).firstMatch(body)?.group(1);
    final description = RegExp(
      r'<error-description[^>]*>(.*?)</error-description>',
      dotAll: true,
    ).firstMatch(body)?.group(1);
    if (code != null || description != null) {
      final parts = <String>[];
      if (code != null) {
        parts.add('code $code');
      }
      if (description != null) {
        parts.add(description.trim());
      }
      return parts.join(': ');
    }
    return body.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}

class LabArchivesException implements Exception {
  const LabArchivesException(this.message);

  final String message;

  @override
  String toString() => message;
}
